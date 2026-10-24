#!/system/bin/sh
# =============================================================================
#  nfc_diag2.sh —— 第二轮取证（针对「开机就没有 I2C 响应」这条线索）
#
#  v1 已确认的事：补丁生效、HAL 活着、但 i2c_geni 报 GSI 通道错误、
#                chipid 读成 0x00、com.android.nfc 每 15 秒 ANR 一次。
#  v2 要查清的事：最新 tombstone 是谁崩的 / GPI-QUP 初始化有没有报错 /
#                固件文件在不在 / 芯片到底有没有被真正断电复位。
#
#  用法：su -c "sh /sdcard/nfc_diag2.sh"
#  输出：/sdcard/nfc_diag2.txt   （只读，不改任何东西）
# =============================================================================

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH
OUT=/sdcard/nfc_diag2.txt
rm -f "$OUT"
log() { echo "$@" | tee -a "$OUT"; }
sec() { log ""; log "======== $* ========"; }

log "nfc_diag2  $(date '+%Y-%m-%d %H:%M:%S')"
log "内核 $(uname -r)"
log "uptime: $(cat /proc/uptime)"
log "fingerprint: $(getprop ro.build.fingerprint)"

# ------------------------------------------------------------- 1. 芯片有没有应答
sec "1. 芯片应答状态"
log "vendor.qti.nfc.chipid = [$(getprop vendor.qti.nfc.chipid)]   （非 0x00 才是通了）"
log "vendor.qti.nfc.fwver  = [$(getprop vendor.qti.nfc.fwver)]"
log "nfc.initialized       = [$(getprop nfc.initialized)]"
log "nqnfcinfo 服务        = [$(getprop init.svc.nqnfcinfo)]"
log "HAL 服务              = [$(getprop init.svc.nqnfc_1_2_hal_service)]"
log "HAL pid               = $(pidof vendor.nxp.hardware.nfc@1.2-service)"

# ------------------------------------------------------------- 2. 最新 tombstone
sec "2. 最新 tombstone（谁在崩）"
TB=$(ls -t /data/tombstones/tombstone_* 2>/dev/null | grep -v '\.pb$' | head -n 1)
if [ -n "$TB" ]; then
    log "文件: $TB"
    ls -l "$TB" | tee -a "$OUT"
    log "--- 头部 45 行（signal / abort message / pid / 栈顶）---"
    head -n 45 "$TB" | tee -a "$OUT"
    log "--- ABORT MESSAGE 行 ---"
    grep -i 'abort message' "$TB" | tee -a "$OUT"
    log "--- backtrace 前 25 行 ---"
    sed -n '/^backtrace:/,$p' "$TB" | head -n 25 | tee -a "$OUT"
else
    log "没有 tombstone"
fi
log ""
log "--- 全部 tombstone 列表 ---"
ls -lt /data/tombstones/ 2>/dev/null | head -n 10 | tee -a "$OUT"

# --------------------------------------------------- 3. QUP/GPI/SE 初始化日志
sec "3. QUP / GPI / GENI / 驱动 probe（dmesg 头部，剔除刷屏）"
dmesg 2>/dev/null | grep -iE 'gpi|qup|geni|se_|i2c' | grep -viE 'GSI QN err|nfc_write' | head -n 100 | tee -a "$OUT"
log ""
log "--- nq-nci probe / 电源 / 中断相关 ---"
dmesg 2>/dev/null | grep -iE 'nq-nci|nfc' | grep -viE 'nfc_write: failed' | head -n 60 | tee -a "$OUT"
log ""
log "--- GSI 错误计数 ---"
log "GSI QN err 次数: $(dmesg 2>/dev/null | grep -c 'GSI QN err')"
log "nfc_write 失败次数: $(dmesg 2>/dev/null | grep -c 'nfc_write: failed')"
log "最后 5 条带时间戳的错误:"
dmesg 2>/dev/null | grep -iE 'GSI QN err|nfc_write: failed|nq-nci' | tail -n 5 | tee -a "$OUT"

# --------------------------------------------------- 4. 固件与设备节点
sec "4. 固件 / 设备节点 / i2c 适配器"
log "--- /vendor/firmware 里 qup/gpi 相关 ---"
ls -l /vendor/firmware/*gpi* /vendor/firmware/*qup* /vendor/firmware/*qupv3* 2>/dev/null | tee -a "$OUT" || log "(无)"
log "--- /vendor/firmware 全量前 40 个 ---"
ls /vendor/firmware 2>/dev/null | head -n 40 | tr '\n' ' ' | tee -a "$OUT"
log ""
log "--- 设备节点 ---"
ls -l /dev/nq-nci /dev/i2c-* 2>/dev/null | tee -a "$OUT"
log "--- i2c 适配器（第几个是 NFC 总线）---"
for d in /sys/bus/i2c/devices/i2c-*; do
    [ -e "$d/name" ] || continue
    log "$(basename $d) : $(cat $d/name 2>/dev/null)"
done 2>/dev/null | head -n 30
log "--- 2-0028 是谁 ---"
log "$(cat /sys/bus/i2c/devices/2-0028/name 2>/dev/null || echo '(不存在)')"

# --------------------------------------------------- 5. HAL 日志（剔除刷屏）
sec "5. HAL / NFC 关键日志（剔除 CardEmulation 刷屏）"
logcat -b all -d 2>/dev/null \
  | grep -iE 'NxpNci|NxpTml|nq-nci|NfcAdaptation|NfcService|nfc_nci|phNxpNciHal' \
  | grep -viE 'CardEmulation Service is null|at (android|com)\.|could not retrieve NFC service' \
  | tail -n 250 | tee -a "$OUT"

log ""
log "======== 完成，把 /sdcard/nfc_diag2.txt 发出来 ========"
