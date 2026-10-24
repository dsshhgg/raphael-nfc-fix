#!/system/bin/sh
# =============================================================================
#  nfc_diag3.sh  ——  NFC 芯片「不应答」的复位重试 + 取证
#
#  背景（已确认的事实）：
#    * 修复模块生效（/vendor 里的 HAL 已是补丁版，bind mount OK）
#    * 但 I2C 上 NFC 一直没应答：
#        vendor.qti.nfc.chipid = 0x00 / vendor.qti.nfc.fwver = 00.00.00
#        dmesg: i2c_geni a84000.i2c: GSI QN err:0x0, status:0x4d3, err:2
#               nq-nci 2-0028: nfc_write: failed to write after 3 retries
#    * a84000 = qupv3_se9_i2c = NFC 所在的那条 I2C（已从 dtbo 核对：
#      fragment@51 target=qupv3_se9_i2c，nq@28 addr=0x28，ven=gpio103,
#      firm=gpio48, irq=gpio47, clkreq=gpio113 —— 设备树配置本身是对的）
#
#  本脚本做两件事：
#    1) 取证：GPIO 状态、哪几条 I2C 总线上有设备（用来判断 GENI/GSI 只有 NFC
#       这条坏，还是全坏）、当前 chipid、dmesg 里 NFC 相关行。
#    2) 实验：把 nq-nci 驱动 unbind/bind 一次（等价于给芯片重新上电+复位），
#       然后重启 nqnfcinfo 让它重新读 chip id，看 chipid 会不会从 0x00 变成
#       真实值。**这是只读+驱动重绑，不改任何文件，重启即恢复原状。**
#
#  用法（root）： sh /sdcard/nfc_diag3.sh
#  产物：        /sdcard/nfc_diag3.txt   （把它整个发回来）
#  可选：        sh /sdcard/nfc_diag3.sh norebind   —— 只取证，不做重绑实验
# =============================================================================

OUT=/sdcard/nfc_diag3.txt
: >"$OUT"
log() { echo "$*" | tee -a "$OUT"; }
sec() { echo "" | tee -a "$OUT"; echo "===== $* =====" | tee -a "$OUT"; }
ts()  { date '+%m-%d %H:%M:%S'; }

DO_REBIND=1
[ "$1" = "norebind" ] && DO_REBIND=0

NFC_LIB=/vendor/lib64/nfc_nci.nqx.default.hw.so
DEV=/dev/nq-nci
HAL_SVC=nqnfc_1_2_hal_service
I2C_ADDR=2-0028

log "nfc_diag3.sh   $(ts)   rebind=$DO_REBIND"

# ---------------------------------------------------------------- 0. 模块状态
sec "0. module / lib state"
if [ -d /data/adb/modules/nfc_abort_fix ]; then
    log "module dir : present"
    log "module.prop: $(grep -E '^(version|versionCode)=' /data/adb/modules/nfc_abort_fix/module.prop 2>/dev/null | tr '\n' ' ')"
    log "post-mount.sh: $([ -f /data/adb/modules/nfc_abort_fix/post-mount.sh ] && echo yes || echo no)"
    [ -f /data/adb/modules/nfc_abort_fix/nfc_fix.log ] && {
        log "--- nfc_fix.log (tail 20) ---"
        tail -n 20 /data/adb/modules/nfc_abort_fix/nfc_fix.log | tee -a "$OUT"
    }
else
    log "module dir : MISSING"
fi
if [ -f "$NFC_LIB" ]; then
    log "live site  : $(od -An -tx1 -j 121104 -N 4 "$NFC_LIB" 2>/dev/null)"
    log "live size  : $(wc -c <"$NFC_LIB" 2>/dev/null)"
else
    log "live lib   : MISSING $NFC_LIB"
fi
log "bind mount : $(grep -F " $NFC_LIB " /proc/self/mountinfo 2>/dev/null | grep -c nfc_abort_fix) hit(s)"

# ------------------------------------------------------------ 1. 芯片/属性现状
sec "1. chip id / props (before)"
for p in vendor.qti.nfc.chipid vendor.qti.nfc.fwver nfc.initialized \
         persist.vendor.nfc.fw.downloadmode_force nfc.fw.downloadmode_force; do
    log "  $p = $(getprop "$p")"
done
log "  init.svc.$HAL_SVC = $(getprop "init.svc.$HAL_SVC")"
log "  init.svc.nqnfcinfo = $(getprop init.svc.nqnfcinfo)"
log "  HAL pid = $(pidof vendor.nxp.hardware.nfc@1.2-service)"

# --------------------------------------------------------------- 2. GPIO 状态
sec "2. gpio state (nfc pins: irq=47 firm=48 ven=103 clkreq=113)"
if [ -r /sys/kernel/debug/gpio ]; then
    grep -iE 'nfc|gpio-?(47|48|103|113) ' /sys/kernel/debug/gpio 2>/dev/null | tee -a "$OUT"
    log "--- tlmm totals ---"
    grep -c gpio /sys/kernel/debug/gpio 2>/dev/null
else
    log "/sys/kernel/debug/gpio not readable (debugfs off?)"
fi

# --------------------------------------------- 3. 哪些 I2C 总线上真的有设备
sec "3. i2c topology (which geni buses actually have devices)"
for d in /sys/bus/i2c/devices/*; do
    [ -e "$d/name" ] || continue
    log "  $(basename "$d")  $(cat "$d/name" 2>/dev/null)"
done
log "--- i2c controllers ---"
for d in /sys/bus/i2c/devices/i2c-*; do
    [ -e "$d/name" ] || continue
    log "  $(basename "$d") name=$(cat "$d/name" 2>/dev/null)"
done
log "--- /dev/i2c-* ---"
ls -l /dev/i2c-* 2>/dev/null | tee -a "$OUT"

# ------------------------------------------------------- 4. NFC 相关 dmesg
sec "4. dmesg (nfc / nq / geni / gsi / gpi)"
dmesg 2>/dev/null | grep -iE 'nq-nci|nfc|a84000|gsi|gpi|qup' | tail -n 60 | tee -a "$OUT"
log "--- counts ---"
log "  GSI QN err lines : $(dmesg 2>/dev/null | grep -c 'GSI QN err')"
log "  nfc_write failed : $(dmesg 2>/dev/null | grep -c 'nfc_write')"

MARK="$(dmesg 2>/dev/null | wc -l)"

# ----------------------------------------- 4.5 最新 ANR 里 com.android.nfc 的栈
sec "4.5 newest ANR block for com.android.nfc (where startup blocks)"
ANR="$(ls -t /data/anr/anr_* 2>/dev/null | head -n 1)"
if [ -n "$ANR" ]; then
    log "file: $ANR  ($(wc -c <"$ANR" 2>/dev/null) bytes)"
    log "--- pid headers in this file (head 10) ---"
    grep -E '^----- pid ' "$ANR" 2>/dev/null | head -n 10 | tee -a "$OUT"
    log "--- com.android.nfc block (first 90 lines, main thread inside) ---"
    awk '/^----- pid /{n=0}
         /Cmd line: com\.android\.nfc/{n=1; c=0}
         n==1{print; c++; if(c>90) exit}' "$ANR" 2>/dev/null | tee -a "$OUT" | wc -l
    log "--- explicit \"main\" thread of that block (45 lines) ---"
    awk '/Cmd line: com\.android\.nfc/{n=1}
         n==1 && /^"main"/{m=1}
         m==1{print; c++; if(c>45) exit}' "$ANR" 2>/dev/null | tee -a "$OUT" | wc -l
else
    log "no /data/anr/anr_* found"
fi

# --------------------------------------------------- 5. 实验：驱动重绑 + 重读
if [ "$DO_REBIND" = "1" ]; then
    sec "5. EXPERIMENT: power-cycle chip via driver rebind"

    log "-- stop HAL --"
    setprop ctl.stop "$HAL_SVC" 2>/dev/null || stop "$HAL_SVC" 2>/dev/null
    sleep 2
    log "   init.svc.$HAL_SVC = $(getprop "init.svc.$HAL_SVC")"

    DRV=""
    for cand in /sys/bus/i2c/drivers/nq-nci /sys/bus/i2c/drivers/nfc-nci \
                /sys/bus/i2c/drivers/nxp-nci-i2c /sys/bus/i2c/drivers/nq-nci-i2c; do
        [ -d "$cand" ] && { DRV=$cand; break; }
    done
    log "   driver dir = ${DRV:-NOT FOUND}"

    if [ -n "$DRV" ] && [ -e "$DRV/unbind" ]; then
        log "-- unbind $I2C_ADDR --"
        echo "$I2C_ADDR" >"$DRV/unbind" 2>&1 | tee -a "$OUT"
        sleep 1
        log "-- bind $I2C_ADDR (driver re-probes, toggles VEN) --"
        echo "$I2C_ADDR" >"$DRV/bind" 2>&1 | tee -a "$OUT"
        sleep 3
        log "-- dmesg since mark --"
        dmesg 2>/dev/null | tail -n +"$((MARK + 1))" | tee -a "$OUT"
    else
        log "   !! no unbind node, skip rebind"
    fi

    log "-- restart nqnfcinfo to re-read chip id --"
    setprop ctl.restart nqnfcinfo 2>/dev/null
    sleep 4
    log "   init.svc.nqnfcinfo = $(getprop init.svc.nqnfcinfo)"
    for p in vendor.qti.nfc.chipid vendor.qti.nfc.fwver; do
        log "   $p = $(getprop "$p")"
    done

    log "-- start HAL again --"
    setprop ctl.start "$HAL_SVC" 2>/dev/null || start "$HAL_SVC" 2>/dev/null
    sleep 3
    log "   init.svc.$HAL_SVC = $(getprop "init.svc.$HAL_SVC")"
    log "   HAL pid = $(pidof vendor.nxp.hardware.nfc@1.2-service)"
else
    sec "5. rebind experiment SKIPPED (norebind)"
fi

# ------------------------------------------------------------- 6. 结论提示
sec "6. how to read this"
log "  * chipid 从 0x00 变成 4 位非零 => 芯片只是没被正确上电/复位，重绑能救，"
log "    可以在模块的 service.sh 里自动做一次 rebind。"
log "  * chipid 仍是 0x00 => 芯片侧（供电/焊接/损坏）或 QUP-GSI 通道的问题，"
log "    看第 4 节的 a84000 错误是否还在，以及第 3 节其它总线是否正常。"
log "  * 第 3 节里如果除了 2-0028 之外还有别的 i2c 设备（比如功放 tfa98xx、"
log "    goodix 指纹），说明 GENI/GSI 整体是好的，问题只在 NFC 那条通道。"
log ""
log "done $(ts)  -> $OUT"
