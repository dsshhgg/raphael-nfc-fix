#!/system/bin/sh
# 卸载阶段：撤掉影子挂载
TARGET=/system/app/NQNfcNci
BASE=/data/adb/nfc_mfc_retx_fix
if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
  umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null
fi
rm -rf "$BASE/stage" 2>/dev/null
echo "影子挂载已撤掉；建议重启一次让 com.android.nfc 重新加载原厂库"
