PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

ui_print "- NFC 加密卡防崩模块"

CONF=/vendor/etc/libnfc-nxp.conf
PAYLOAD="$MODPATH/system/vendor/etc/libnfc-nxp.conf"

if [ ! -f "$CONF" ]; then
  ui_print "! 设备上找不到 $CONF"
  abort "  这台机器不是预期的 ROM，已中止"
fi
if [ ! -f "$PAYLOAD" ]; then
  ui_print "! 模块载荷缺失"
  abort "  压缩包不完整，已中止"
fi

size=$(wc -c < "$CONF" | tr -d ' \n')
ui_print "- 设备配置大小: $size 字节"
if [ "$size" -lt 15000 ] || [ "$size" -gt 17000 ]; then
  ui_print "! 配置大小异常（期望 $WANT 附近）"
  abort "  拒绝在不匹配的 ROM 上安装"
fi

cur=$(grep -m1 '^MIFARE_READER_ENABLE=' "$CONF")
ui_print "- 当前设置: $cur"
case "$cur" in
  MIFARE_READER_ENABLE=0x01|MIFARE_READER_ENABLE=0x00) : ;;
  *) abort "  意外的 MIFARE_READER_ENABLE 值，已中止" ;;
esac

u=$(grep -m1 '^MIFARE_READER_ENABLE=' "$PAYLOAD")
if [ "$u" != "MIFARE_READER_ENABLE=0x00" ]; then
  abort "  载荷内容不正确，已中止"
fi
ui_print "- 载荷校验通过: $u"

for f in customize.sh post-fs-data.sh post-mount.sh service.sh action.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f" 2>/dev/null
done

mkdir -p /data/adb/nfc_mifare_safe 2>/dev/null
ui_print "- 重启后生效（/vendor 分区本身不会被修改）"
