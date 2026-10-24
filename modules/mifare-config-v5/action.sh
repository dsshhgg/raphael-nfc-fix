PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

echo "== NFC 加密卡防崩模块状态 =="
TARGET=/vendor/etc/libnfc-nxp.conf
echo "配置文件: $TARGET"
echo "MIFARE 设置: $(grep -m1 '^MIFARE_READER_ENABLE=' "$TARGET" 2>/dev/null)"
echo "覆盖方式: $(grep -c 'libnfc-nxp.conf' /proc/mounts 2>/dev/null) 条 bind mount"
echo "stock_mode 开关: $([ -f /data/adb/nfc_mifare_safe/stock_mode ] && echo 存在 || echo 不存在)"
echo "NFC HAL pid: $(pidof vendor.nxp.hardware.nfc@1.2-service)"
echo "NFC 状态: $(dumpsys nfc 2>/dev/null | head -1)"
echo
echo "== 最近日志 =="
tail -12 /data/adb/nfc_mifare_safe/nfc_fix.log 2>/dev/null
