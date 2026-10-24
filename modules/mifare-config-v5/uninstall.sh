PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

TARGET=/vendor/etc/libnfc-nxp.conf
mount | grep -q "libnfc-nxp.conf" && umount "$TARGET" 2>/dev/null
echo "已卸载 overlay；/vendor 分区本身从未被修改"
exit 0
