#!/system/bin/sh
# =============================================================================
#  nfc_writewatch.sh —— 抓「写卡失败」那一刻的内核日志
#
#  背景：这台机器 NFC 读卡正常、写卡不行；NXP HAL 在写路径上重试 5 次耗尽后
#        会 abort() 自杀（tombstone 里 phNxpNciHal_write_unlocked+1112）。
#        要定位「写」到底死在哪一层，必须在写卡那一瞬间抓 dmesg：
#          - 如果出现 nq-nci 2-0028: nfc_write: failed to write  -> I2C 写失败
#          - 如果出现 i2c_geni ... GSI QN err ... , err:2        -> GPI/GSI 通道错误
#          - 如果两者都没有，只有 logcat 里 HAL 的超时              -> HAL 自己的超时逻辑
#
#  用法（要在电脑上或手机上开 root shell）：
#    su -c "sh /sdcard/nfc_writewatch.sh start"    # 开始录制
#    ... 然后在 NFC Tools / 系统里执行一次写卡，失败也没关系 ...
#    su -c "sh /sdcard/nfc_writewatch.sh stop"     # 停止并打印摘要
#
#  产物：
#    /sdcard/nfc_write.dmesg     内核日志（只追加新行）
#    /sdcard/nfc_write.logcat    过滤后的 logcat（nfc / nq-nci / i2c_geni / GSI）
#    /sdcard/nfc_write.summary   摘要（stop 时生成，直接把这个发我）
# =============================================================================

OUT=/sdcard/nfc_write
DMESG_F=$OUT.dmesg
LOGCT_F=$OUT.logcat
SUM_F=$OUT.summary
DMESG_PID_F=$OUT.dmesg.pid
LOGCT_PID_F=$OUT.logcat.pid

log() { echo "$*"; }

find_root() {
  if [ "$(id -u 2>/dev/null)" = "0" ]; then return 0; fi
  for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su; do
    if [ -x "$s" ]; then
      exec "$s" -c "sh $0 $*"
    fi
  done
  echo "!! 需要 root（su）。请用: su -c \"sh /sdcard/nfc_writewatch.sh $*\""
  exit 1
}

start() {
  log "== 开始录制 NFC 写卡现场 =="
  rm -f "$DMESG_F" "$LOGCT_F" "$SUM_F"

  # --- 内核日志：每秒把自上次以来新增的行追加进文件（不依赖 dmesg -w） ---
  N=$(dmesg 2>/dev/null | wc -l)
  echo "$N" > "$OUT.dmesg.base"
  (
    while :; do
      M=$(dmesg 2>/dev/null | wc -l)
      if [ "$M" -gt "$N" ]; then
        dmesg 2>/dev/null | tail -n +$((N + 1)) >> "$DMESG_F"
        N=$M
      elif [ "$M" -lt "$N" ]; then
        # ring buffer 回绕了，从头再来
        dmesg 2>/dev/null > "$DMESG_F"
        N=$M
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  echo $! > "$DMESG_PID_F"

  # --- logcat：只留 NFC 相关 tag，避免几十 MB/s 的刷屏 ---
  (
    logcat -b all -v threadtime 2>/dev/null \
      | grep -iE 'nfc|nq-nci|nq-nci|i2c_geni|GSI QN|NxpNci|phTml|phNxp' \
      >> "$LOGCT_F"
  ) >/dev/null 2>&1 &
  echo $! > "$LOGCT_PID_F"

  log "   已启动："
  log "     dmesg  -> $DMESG_F   (pid $(cat $DMESG_PID_F 2>/dev/null))"
  log "     logcat -> $LOGCT_F   (pid $(cat $LOGCT_PID_F 2>/dev/null))"
  log ""
  log "   现在去执行一次【写卡】（NFC Tools -> 写 -> 选一个 NDEF 记录 -> 贴卡）"
  log "   失败/报错/闪退都没关系，尽量多贴几次，持续 10~20 秒。"
  log "   做完回来执行："
  log "     su -c \"sh /sdcard/nfc_writewatch.sh stop\""
}

stop() {
  log "== 停止录制 =="
  for f in "$DMESG_PID_F" "$LOGCT_PID_F"; do
    if [ -f "$f" ]; then
      p=$(cat "$f" 2>/dev/null)
      [ -n "$p" ] && kill "$p" 2>/dev/null
      # 杀掉包装的子 shell 及其 grep
      pkill -P "$p" 2>/dev/null
      rm -f "$f"
    fi
  done
  pkill -f 'nfc_writewatch.sh' 2>/dev/null
  sleep 1

  {
    echo "######## nfc_write.summary ########"
    echo "# 时间: $(date)"
    echo "# 设备: $(getprop ro.product.device) / $(getprop ro.build.display.id)"
    echo "# 内核: $(uname -r)"
    echo
    echo "===== 模块状态 ====="
    if [ -d /data/adb/modules/nfc_abort_fix ]; then
      grep -E '^(name|version)=' /data/adb/modules/nfc_abort_fix/module.prop 2>/dev/null
      if [ -f /data/adb/modules/nfc_abort_fix/disable ]; then
        echo "模块: 已禁用 (disable 标记存在) -> 运行的是原厂 HAL"
      else
        echo "模块: 已启用"
      fi
    else
      echo "模块: 未安装"
    fi
    echo "live site: $(od -An -tx1 -j 121684 -N 4 /vendor/lib64/nfc_nci.nqx.default.hw.so 2>/dev/null | tr -d ' ')"
    echo
    echo "===== 关键计数（本次录制期间）====="
    if [ -f "$DMESG_F" ]; then
      echo "dmesg 新增行数        : $(wc -l < "$DMESG_F")"
      echo "nfc_write: failed 次数: $(grep -c 'nfc_write: failed' "$DMESG_F" 2>/dev/null)"
      echo "GSI QN err 次数       : $(grep -c 'GSI QN err' "$DMESG_F" 2>/dev/null)"
      echo "i2c_geni 相关         : $(grep -c 'i2c_geni' "$DMESG_F" 2>/dev/null)"
      echo "nq-nci 相关           : $(grep -c 'nq-nci' "$DMESG_F" 2>/dev/null)"
      echo
      echo "----- dmesg 里所有 nfc / i2c_geni / GSI 行（最多 120 行）-----"
      grep -iE 'nfc|nq-nci|i2c_geni|GSI QN|gpi' "$DMESG_F" 2>/dev/null | tail -n 120
    else
      echo "!! 没有捕获到 dmesg 文件"
    fi
    echo
    echo "===== logcat 里的关键行（最多 120 行）====="
    if [ -f "$LOGCT_F" ]; then
      echo "logcat 行数: $(wc -l < "$LOGCT_F")"
      grep -iE 'fail|error|timeout|busy|abort|retry|NxpNciHal_write|phTmlNfc' "$LOGCT_F" 2>/dev/null | tail -n 120
    else
      echo "!! 没有捕获到 logcat 文件"
    fi
    echo
    echo "===== 当前 HAL 状态 ====="
    echo "HAL pid     : $(pidof vendor.nxp.hardware.nfc@1.2-service)"
    echo "init.svc    : $(getprop init.svc.nqnfc_1_2_hal_service)"
    echo "chipid      : $(getprop vendor.qti.nfc.chipid)"
    echo "fwver       : $(getprop vendor.qti.nfc.fwver)"
    echo "nfc.init    : $(getprop nfc.initialized)"
    echo
    echo "######## 把上面的内容整段发我 ########"
  } > "$SUM_F" 2>&1

  log ""
  log "摘要已写入：$SUM_F"
  log "----- 摘要开始 -----"
  cat "$SUM_F"
  log "----- 摘要结束 -----"
  log ""
  log "如果 dmesg 里有 nfc_write / GSI QN err 行，那可能是 I2C 传输问题；"
  log "如果一条都没有，只有 logcat 里的 fail/timeout，那就是 HAL 层超时。"
}

case "${1:-start}" in
  start) find_root "$1"; start ;;
  stop)  find_root "$1"; stop ;;
  *)     echo "用法: sh $0 start|stop"; exit 2 ;;
esac
