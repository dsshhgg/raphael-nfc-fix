#!/system/bin/sh
# 安装阶段：把原厂 APK + 一整套原生库（含已打补丁的 libsn100nfc-nci.so）预置到
# /data/adb/nfc_mfc_retx_fix/stage，之后由 post-fs-data.sh 影子挂载到
# /system/app/NQNfcNci。
#
# v6.1 关键修正：lib/arm64 里必须放「完整」的一套库（32 个），只放一个
# libsn100nfc-nci.so 会让 com.android.nfc 反复崩溃——因为原厂 APK 里是自带整套
# 运行库的，一旦磁盘上出现真实的 nativeLibraryDir，nativeloader 就会只认这个目录，
# 其余库（libsn100nfc_nci_jni.so、libclang_rt.ubsan_*.so、libbase.so…）找不到就炸。
PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

ui_print "- NFC 写卡修复模块 v6.1 (MFC 重传钳制)"

FP=$(getprop ro.build.fingerprint)
ui_print "- 机型: $FP"
case "$FP" in
  *raphael*) : ;;
  *) ui_print "! 这台机器不是 raphael"; abort "  拒绝安装";;
esac
case "$FP" in
  *OS4*) : ;;
  *) ui_print "! 不是 HyperOS 4 的指纹"; abort "  这个补丁只针对 HOS4 的 MW15 框架库";;
esac

SRC_APK=/system/app/NQNfcNci/NQNfcNci.apk
[ -f "$SRC_APK" ] || abort "  找不到 $SRC_APK，已中止"

LIBDIR=$MODPATH/payload/lib/arm64
[ -d "$LIBDIR" ] || abort "  载荷目录缺失，压缩包不完整，已中止"
NLIB=$(ls "$LIBDIR" | wc -l | tr -d ' \n')
[ "$NLIB" = "32" ] || abort "  载荷库数量不对（$NLIB/32），已中止"
[ "$(wc -c < "$LIBDIR/libsn100nfc-nci.so" | tr -d ' \n')" = "2034440" ] || abort "  补丁库大小不对，已中止"

BASE=/data/adb/nfc_mfc_retx_fix
STAGE=$BASE/stage
mkdir -p "$BASE" 2>/dev/null
rm -rf "$STAGE"
mkdir -p "$STAGE/lib/arm64" || abort "  建目录失败"

ui_print "- 复制原厂 APK 到影子目录（约 20MB，稍等）"
cp -f "$SRC_APK" "$STAGE/NQNfcNci.apk" || abort "  复制 APK 失败"

ui_print "- 铺开 $NLIB 个原生库到影子 lib/arm64"
cp -f "$LIBDIR"/* "$STAGE/lib/arm64"/ || abort "  复制原生库失败"
if [ -f "$BASE/use_cap2" ] && [ -f "$MODPATH/payload/lib/arm64_cap2/libsn100nfc-nci.so" ]; then
  ui_print "- 使用 clamp2（最多 2 次尝试）"
  cp -f "$MODPATH/payload/lib/arm64_cap2/libsn100nfc-nci.so" "$STAGE/lib/arm64/libsn100nfc-nci.so" || abort "  替换 clamp2 失败"
else
  ui_print "- 使用 clamp1（只试 1 次，对齐澎湃2 MW10 行为）"
fi

chmod 0755 "$STAGE/lib/arm64"/*.so 2>/dev/null
chmod 0644 "$STAGE/NQNfcNci.apk" 2>/dev/null

ui_print "- 修正 SELinux 上下文"
chcon -R u:object_r:system_file:s0 "$STAGE" 2>/dev/null

ui_print "- 影子目录: $STAGE"
ui_print "    apk $(wc -c < "$STAGE/NQNfcNci.apk" | tr -d ' \n') 字节"
ui_print "    lib $(ls "$STAGE/lib/arm64" | wc -l) 个（libsn100nfc-nci.so $(wc -c < "$STAGE/lib/arm64/libsn100nfc-nci.so" | tr -d ' \n') 字节）"

for f in customize.sh post-fs-data.sh service.sh action.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f" 2>/dev/null
done

ui_print "- 重启后生效（vendor 分区不会被改）"
ui_print "- 想回到原厂：创建 $BASE/stock_mode 再重启"
ui_print "- 如果开机后 NFC 出问题：重启一次就会自动禁用（看门狗）"
