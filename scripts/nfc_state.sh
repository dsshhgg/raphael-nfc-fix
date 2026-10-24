#!/system/bin/sh
# =============================================================================
#  nfc_state.sh  ——  NFC 开关消失 / 适配器状态 取证 + 模块一键开关
#
#  为什么写这个：
#    设置里的 NFC 开关不是固定的，它是 Settings 动态加的 —— 只有
#    NfcAdapter.getDefaultAdapter() 非 null（也就是 com.android.nfc 活着、
#    并且成功拿到 NFC HAL 服务）时才会显示。NfcService 反复启动超时被 ANR
#    杀掉 -> 适配器变 null -> 开关整项消失。
#
#  用法（root）：
#    sh /sdcard/nfc_state.sh          # 只取证，输出 /sdcard/nfc_state.txt
#    sh /sdcard/nfc_state.sh off      # 给模块打 disable 标记（重启后 HAL 回原厂）
#    sh /sdcard/nfc_state.sh on       # 去掉 disable 标记（重启后重新启用补丁）
#
#  说明：disable 标记是 KernelSU / Magisk 的标准机制，文件存在 = 该模块本次
#        开机不加载。`off` 之后必须重启才生效，`on` 同理。
# =============================================================================

MOD=/data/adb/modules/nfc_abort_fix
OUT=/sdcard/nfc_state.txt
HAL=vendor.nxp.hardware.nfc@1.2-service
HAL_SVC=nqnfc_1_2_hal_service

log() { echo "$*" | tee -a "$OUT"; }
sec() { echo "" | tee -a "$OUT"; echo "===== $* =====" | tee -a "$OUT"; }

# ---------------------------------------------------------------- 模块开关
case "$1" in
off)
    mkdir -p "$MOD" 2>/dev/null
    : >"$MOD/disable"
    echo "module DISABLED (marker created): $MOD/disable"
    echo "reboot to take effect:  su -c reboot"
    exit 0
    ;;
on)
    rm -f "$MOD/disable"
    echo "module ENABLED (marker removed)"
    echo "reboot to take effect:  su -c reboot"
    exit 0
    ;;
esac

: >"$OUT"
log "nfc_state.sh   $(date '+%m-%d %H:%M:%S')"

# --------------------------------------------------------------- 0. 模块状态
sec "0. module"
if [ -d "$MOD" ]; then
    log "  dir          : $MOD"
    log "  disable flag : $([ -f "$MOD/disable" ] && echo YES '(this boot: OFF)' || echo no)"
    log "  remove flag  : $([ -f "$MOD/remove" ] && echo YES || echo no)"
    log "  version      : $(grep -E '^version=' "$MOD/module.prop" 2>/dev/null)"
else
    log "  module dir MISSING"
fi
if [ -f /vendor/lib64/nfc_nci.nqx.default.hw.so ]; then
    log "  live site    : $(od -An -tx1 -j 121684 -N 4 /vendor/lib64/nfc_nci.nqx.default.hw.so 2>/dev/null)   (e3ffff17=patched  cf540094=stock)"
fi
log "  mounts       : $(grep -c nfc_abort_fix /proc/self/mountinfo 2>/dev/null) entry(s)"

# -------------------------------------------- 1. 系统是否把 NFC 当成"有硬件"
sec "1. features / services (this is what Settings looks at)"
log "--- pm features ---"
pm list features 2>/dev/null | grep -i nfc | tee -a "$OUT"
log "--- service list (binder) ---"
service list 2>/dev/null | grep -i nfc | tee -a "$OUT"
log "--- package com.android.nfc ---"
dumpsys package com.android.nfc 2>/dev/null | grep -E 'userId=|enabled=|stopped=|versionName=' | head -n 8 | tee -a "$OUT"

# --------------------------------------------------- 2. HAL 与框架进程现状
sec "2. processes"
log "  init.svc.$HAL_SVC = $(getprop "init.svc.$HAL_SVC")"
log "  HAL pid           = $(pidof $HAL)"
log "  nfc process       = $(pidof com.android.nfc)"
log "  init.svc.nqnfcinfo= $(getprop init.svc.nqnfcinfo)"
log "  chipid            = $(getprop vendor.qti.nfc.chipid)"
log "  nfc.initialized   = $(getprop nfc.initialized)"
log "--- dumpsys nfc (head 40) ---"
dumpsys nfc 2>&1 | head -n 40 | tee -a "$OUT"

# ------------------------------------------------------ 3. 最近的失败链路
sec "3. recent logs (last 60 nfc-related lines)"
logcat -b main -d -v time 2>/dev/null | grep -iE 'nfc|NfcService|NfcAdapter' \
    | tail -n 60 | tee -a "$OUT"

sec "4. dmesg nfc (tail 25)"
dmesg 2>/dev/null | grep -iE 'nq-nci|a84000|GSI QN' | tail -n 25 | tee -a "$OUT"

sec "5. props"
getprop 2>/dev/null | grep -iE 'nfc' | tee -a "$OUT"

log ""
log "done -> $OUT"
