#!/system/bin/sh
# 早期阶段：把影子目录 bind 挂到 /system/app/NQNfcNci
# 原厂 /system/app/NQNfcNci 里只有 APK，没有 lib/ 目录；com.android.nfc 的
# legacyNativeLibraryDir 正是 /system/app/NQNfcNci/lib，所以这里放「整套」原生库，
# nativeloader 就会从磁盘加载我们这份（APK 内容与原厂逐字节相同）。
PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

MODDIR=${0%/*}
BASE=/data/adb/nfc_mfc_retx_fix
STAGE=$BASE/stage
LOGDIR=$BASE
mkdir -p "$LOGDIR" 2>/dev/null
exec >>"$LOGDIR/nfc_fix.log" 2>&1
echo "--- $(date '+%F %T') post-fs-data (v6.1) ---"

if [ -f "$LOGDIR/stock_mode" ]; then
  echo "stock_mode 存在，保持原厂，不做影子挂载"
  exit 0
fi
if [ -f "$LOGDIR/auto_reverted" ]; then
  echo "auto_reverted 存在（上次开机看门狗回滚过），本次不挂载；确认没问题后删掉它再重启"
  exit 0
fi

TARGET=/system/app/NQNfcNci
[ -d "$TARGET" ] || { echo "目标目录不存在，跳过"; exit 0; }
[ -f "$STAGE/NQNfcNci.apk" ] || { echo "影子 APK 缺失，跳过（重装模块）"; exit 0; }
[ -f "$STAGE/lib/arm64/libsn100nfc-nci.so" ] || { echo "影子库缺失，跳过"; exit 0; }
NLIB=$(ls "$STAGE/lib/arm64" 2>/dev/null | wc -l)
echo "影子 lib/arm64 库数量: $NLIB"
if [ "$NLIB" -lt 30 ]; then
  echo "!! 库数量不足（$NLIB），为避免 com.android.nfc 崩溃，放弃挂载——请重装模块"
  touch "$BASE/auto_reverted"
  exit 0
fi

if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
  echo "已经挂过了"
  exit 0
fi

mount -o bind "$STAGE" "$TARGET" 2>/dev/null || mount --bind "$STAGE" "$TARGET" 2>/dev/null
if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
  echo "bind OK"
else
  echo "bind FAILED"
fi
echo "目标库: $(ls "$TARGET/lib/arm64" 2>/dev/null | wc -l) 个; libsn100nfc-nci.so $(wc -c < "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null) 字节"
echo "补丁字节(0x1975a0): $(od -An -tx1 -j 1668512 -N 4 "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | tr -d '\n')"
