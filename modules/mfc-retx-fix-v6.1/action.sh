#!/system/bin/sh
# KSU 管理器里点「操作」按钮时执行：看状态，并可一键回原厂 / 解除看门狗锁定
BASE=/data/adb/nfc_mfc_retx_fix
TARGET=/system/app/NQNfcNci
echo "==== NFC 写卡修复模块 v6.1 ===="
echo "stock_mode    : $([ -f $BASE/stock_mode ] && echo 存在（回原厂） || echo 无)"
echo "auto_reverted : $([ -f $BASE/auto_reverted ] && echo 存在（看门狗已回滚，重启就回原厂） || echo 无)"
echo "挂载          : $(grep -q " $TARGET " /proc/mounts 2>/dev/null && echo 生效 || echo 未生效)"
echo "影子库数量    : $(ls $TARGET/lib/arm64 2>/dev/null | wc -l)"
echo "补丁字节      : $(od -An -tx1 -j 1668512 -N 4 $TARGET/lib/arm64/libsn100nfc-nci.so 2>/dev/null | tr -d '\n')  (clamp1=1f010071 clamp2=1f050071 原厂=1f110071)"
echo "nfc pid       : $(pidof com.android.nfc)"
echo "HAL pid       : $(pidof vendor.nxp.hardware.nfc@1.2-service)"
echo "tombstone(NFC): $(grep -l 'nfc_nci' /data/tombstones/* 2>/dev/null | wc -l)"
echo
echo "==== 日志尾部 ===="
tail -25 "$BASE/nfc_fix.log" 2>/dev/null || echo "  无日志"
echo
echo "常用命令："
echo "  回原厂     : touch $BASE/stock_mode && reboot"
echo "  解除看门狗 : rm -f $BASE/auto_reverted && reboot"
echo "  用 clamp2  : touch $BASE/use_cap2 然后重装模块"
