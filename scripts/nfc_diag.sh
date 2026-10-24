#!/system/bin/sh
# =============================================================================
#  nfc_diag.sh —— K20 Pro / HyperOS4 NFC 启动失败（com.android.nfc ANR）取证脚本
#
#  用法（手机 root 下）：
#      su -c "sh /sdcard/nfc_diag.sh"
#  输出：/sdcard/nfc_diag.txt （同时打印到终端）
#
#  只读：不修改任何分区、不改属性、不重启服务。可以反复跑。
# =============================================================================

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

OUT=/sdcard/nfc_diag.txt
rm -f "$OUT"

log() { echo "$@" | tee -a "$OUT"; }
sec() { log ""; log "================================================================"; log "== $*"; log "================================================================"; }

log "nfc_diag  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "内核: $(uname -r)"
log "fingerprint: $(getprop ro.build.fingerprint)"
log "build.desc:  $(getprop ro.build.description)"

# ---------------------------------------------------------------- 1. 模块状态
sec "1. 修复模块状态"
if [ -f /data/adb/modules/nfc_abort_fix/module.prop ]; then
    log "模块已安装："
    cat /data/adb/modules/nfc_abort_fix/module.prop | tee -a "$OUT"
    if [ -f /data/adb/modules/nfc_abort_fix/disable ]; then
        log ">>> 注意：存在 disable 文件，模块当前【已禁用】"
    else
        log ">>> 模块当前【已启用】（无 disable 文件）"
    fi
    log "--- 模块日志 nfc_fix.log 最后 40 行 ---"
    tail -n 40 /data/adb/modules/nfc_abort_fix/nfc_fix.log 2>/dev/null | tee -a "$OUT"
else
    log ">>> 模块【未安装】或路径不对"
fi

log ""
log "--- KernelSU / Magisk / metamodule ---"
log "KSU=$(getprop KSU)  KSU_VER=$(getprop KSU_VER)"
log "ksud 版本: $(ksud -V 2>/dev/null || echo none)"
log "metamodule -> $(readlink -f /data/adb/metamodule 2>/dev/null || echo '(无)')"
log "magisk: $(command -v magisk >/dev/null 2>&1 && (magisk -v) || echo none)"

# ------------------------------------------------------ 2. /vendor 里的库状态
sec "2. /vendor 库与补丁字节"
LIB=/vendor/lib64/nfc_nci.nqx.default.hw.so
if [ -f "$LIB" ]; then
    log "库存在: $(ls -lZ "$LIB" 2>/dev/null || ls -l "$LIB")"
    log "补丁点 121684 处 4 字节 (e3 ff ff 17 = 已打补丁 / cf 54 00 94 = 原厂):"
    od -An -tx1 -j 121684 -N 4 "$LIB" | tee -a "$OUT"
    log "build-id (应为 9edb171e79cb93d44e64f3e7be460440):"
    od -An -tx1 -j 664 -N 16 "$LIB" | tr -d ' \n'
    log ""
else
    log ">>> $LIB 不存在！"
fi

log ""
log "--- 固件 / 依赖库（64 位与 32 位都要看）---"
ls -lZ /vendor/lib64/libsn100u* /vendor/lib64/libnfc* 2>/dev/null | tee -a "$OUT"
ls -lZ /vendor/lib/libsn100u*   /vendor/lib/libnfc*   2>/dev/null | tee -a "$OUT"
ls -l /vendor/firmware/*nfc* /vendor/firmware/libsn100u* 2>/dev/null | tee -a "$OUT"

log ""
log "--- bind mount 情况（本模块生效时会有一行）---"
grep -F " /vendor/lib64/" /proc/1/mountinfo 2>/dev/null | tee -a "$OUT"

# --------------------------------------------------- 3. 驱动 / 设备节点 / 内核
sec "3. nq-nci 驱动与设备节点"
ls -lZ /dev/nq-nci 2>/dev/null | tee -a "$OUT" || log ">>> /dev/nq-nci 不存在"
log ""
log "--- lsmod ---"
lsmod 2>/dev/null | grep -iE 'nq|nfc|i2c' | tee -a "$OUT" || log "(无相关模块，可能内建)"
log ""
log "--- dmesg 中 nfc/nq-nci/i2c 相关，最后 120 行 ---"
dmesg 2>/dev/null | grep -iE 'nq-nci|nq_nci|nfc|sn100|pn5|i2c' | tail -n 120 | tee -a "$OUT"

# --------------------------------------------------- 4. 进程 / HAL 是否活着
sec "4. NFC 相关进程"
log "--- ps ---"
ps -A 2>/dev/null | grep -iE 'nfc' | tee -a "$OUT"

HALPID=$(pidof vendor.nxp.hardware.nfc@1.2-service 2>/dev/null)
log ""
log "HAL pid = ${HALPID:-（未运行）}"
if [ -n "$HALPID" ]; then
    log "--- HAL 进程映射里加载了哪些 nfc 库 ---"
    grep -iE 'nfc|niar' /proc/$HALPID/maps 2>/dev/null | awk '{print $6}' | sort -u | tee -a "$OUT"
    log ""
    log "--- HAL 进程的 wchan / 状态（判断是否卡在 ioctl）---"
    log "state: $(cat /proc/$HALPID/stat 2>/dev/null | awk '{print $3}')"
    log "wchan: $(cat /proc/$HALPID/wchan 2>/dev/null)"
    log "stack:"
    cat /proc/$HALPID/stack 2>/dev/null | tee -a "$OUT"
fi

APPPID=$(pidof com.android.nfc 2>/dev/null)
log ""
log "com.android.nfc pid = ${APPPID:-（未运行）}"
if [ -n "$APPPID" ]; then
    log "state: $(cat /proc/$APPPID/stat 2>/dev/null | awk '{print $3}')"
    log "wchan: $(cat /proc/$APPPID/wchan 2>/dev/null)"
    log "--- 主线程 stack ---"
    cat /proc/$APPPID/task/$APPPID/stack 2>/dev/null | tee -a "$OUT"
fi

# ------------------------------------------------------------- 5. 服务状态
sec "5. init 服务与属性"
log "nqnfc_1_2_hal_service: $(getprop init.svc.nqnfc_1_2_hal_service)"
log "--- nfc 相关属性 ---"
getprop 2>/dev/null | grep -iE 'nfc|nxp' | tee -a "$OUT"

# ------------------------------------------------------------- 6. logcat
sec "6. logcat（NFC 相关，最后 400 行）"
logcat -b all -d 2>/dev/null | grep -iE 'nfc|NxpNci|NxpExtns|SN100|nq-nci|NfcService|NfcAdaptation' | tail -n 400 | tee -a "$OUT"

sec "7. 最近的 tombstone（如果有）"
ls -lt /data/tombstones/ 2>/dev/null | head -n 8 | tee -a "$OUT"

# --------------------------------------------------------- 8. ANR 现场（可选）
sec "8. ANR 现场"
log "--- /data/anr 目录 ---"
ls -lt /data/anr 2>/dev/null | head -n 6 | tee -a "$OUT"

# 传参数 dump 才会触发 kill -3（只是让 Java 线程栈落盘，不杀进程，安全）
if [ "$1" = "dump" ]; then
    if [ -n "$APPPID" ]; then
        log ">>> 对 com.android.nfc (pid=$APPPID) 发送 SIGQUIT，等待 5 秒落盘..."
        kill -3 "$APPPID" 2>/dev/null
        sleep 5
        ANRF=$(ls -t /data/anr/* 2>/dev/null | head -n 1)
        log "--- 最新 ANR 文件: ${ANRF:-无} ---"
        [ -n "$ANRF" ] && tail -n 200 "$ANRF" | tee -a "$OUT"
        log ""
        log "--- logcat 里该 pid 的 Java 栈（NFC 线程部分）---"
        logcat -d 2>/dev/null | grep -A 60 -iE "Cmd line: com.android.nfc" | tail -n 120 | tee -a "$OUT"
    else
        log ">>> com.android.nfc 没在运行，跳过 kill -3"
    fi
else
    log "（想看 Java 卡在哪就重跑：su -c \"sh /sdcard/nfc_diag.sh dump\"）"
fi

log ""
log "================================================================"
log "完成。把 /sdcard/nfc_diag.txt 整个发出来即可。"
log "================================================================"
