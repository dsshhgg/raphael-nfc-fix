PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

MODDIR=${0%/*}
LOGDIR=/data/adb/nfc_mifare_safe
mkdir -p "$LOGDIR" 2>/dev/null
exec >>"$LOGDIR/nfc_fix.log" 2>&1
echo "--- $(date '+%F %T') post-fs-data ---"
[ -f "$LOGDIR/stock_mode" ] && { echo "stock_mode 开关存在，保持原厂配置"; exit 0; }

TARGET=/vendor/etc/libnfc-nxp.conf
[ -f "$TARGET" ] || { echo "目标不存在"; exit 0; }

cur=$(grep -m1 '^MIFARE_READER_ENABLE=' "$TARGET" 2>/dev/null)
echo "当前: $cur"
[ "$cur" = "MIFARE_READER_ENABLE=0x00" ] && { echo "overlay 已生效"; exit 0; }

PAYLOAD=$MODDIR/system/vendor/etc/libnfc-nxp.conf
[ -f "$PAYLOAD" ] || PAYLOAD=$MODDIR/vendor/etc/libnfc-nxp.conf
[ -f "$PAYLOAD" ] || { echo "载荷缺失，跳过"; exit 0; }

chcon u:object_r:vendor_configs_file:s0 "$PAYLOAD" 2>/dev/null
mount -o bind "$PAYLOAD" "$TARGET" 2>/dev/null || mount --bind "$PAYLOAD" "$TARGET" 2>/dev/null
echo "bind 后: $(grep -m1 '^MIFARE_READER_ENABLE=' "$TARGET" 2>/dev/null)"
