PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

MODDIR=${0%/*}
LOGDIR=/data/adb/nfc_mifare_safe
mkdir -p "$LOGDIR" 2>/dev/null
exec >>"$LOGDIR/nfc_fix.log" 2>&1
echo "--- $(date '+%F %T') service ---"

TARGET=/vendor/etc/libnfc-nxp.conf
cur=$(grep -m1 '^MIFARE_READER_ENABLE=' "$TARGET" 2>/dev/null)
echo "live: $cur"
if [ "$cur" = "MIFARE_READER_ENABLE=0x00" ]; then
  echo "RESULT: 生效（MIFARE reader 已关闭，加密卡不再触发 I2C 拖死）"
else
  echo "RESULT: 未生效，/vendor/etc/libnfc-nxp.conf 仍是原厂值"
fi
if pidof vendor.nxp.hardware.nfc@1.2-service >/dev/null 2>&1; then
  echo "NFC HAL: running (pid $(pidof vendor.nxp.hardware.nfc@1.2-service))"
else
  echo "NFC HAL: 未运行（按需启动）"
fi
