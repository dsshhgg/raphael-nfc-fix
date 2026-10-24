#!/system/bin/sh
# uninstall.sh: 模块卸载时执行。
# 本模块全程不改 /vendor 分区（overlay 或 bind mount），卸载只需拆掉挂载，
# 系统就会回到原始库。这里顺便重启 NFC HAL，让原始库立刻生效。

TARGET=/vendor/lib64/nfc_nci.nqx.default.hw.so
HAL_SVC=nqnfc_1_2_hal_service
HAL_BIN=vendor.nxp.hardware.nfc@1.2-service

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

# 拆掉 post-mount.sh 建立的 same-file bind（只认来源是本模块目录的挂载）
if grep -F " $TARGET " /proc/self/mountinfo 2>/dev/null | grep -F "nfc_abort_fix" >/dev/null 2>&1; then
  umount "$TARGET" 2>/dev/null
fi

OLD_PID=$(pidof "$HAL_BIN" 2>/dev/null)
if ! stop "$HAL_SVC" 2>/dev/null; then
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
fi
sleep 2
start "$HAL_SVC" 2>/dev/null

exit 0
