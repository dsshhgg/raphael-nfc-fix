#!/system/bin/sh
# =============================================================================
#  nfc_v6_test.sh —— 验证 nfc_mfc_retx_fix (v6) 是否真的生效，并抓一次写卡现场
#
#  用法（root）：
#    sh /sdcard/nfc_v6_test.sh status      # 看模块/影子挂载/进程里加载的库/tombstone
#    sh /sdcard/nfc_v6_test.sh watch start # 开始录 logcat+dmesg（过滤 NFC 相关）
#    ... 去贴卡、去用 NFC Tools 写卡，崩了/报错都没关系 ...
#    sh /sdcard/nfc_v6_test.sh watch stop  # 停止并生成摘要，把摘要发回来
#    sh /sdcard/nfc_v6_test.sh stock on|off# 打开/关闭 stock_mode（重启生效）
#    sh /sdcard/nfc_v6_test.sh cap2        # 记录「改用 clamp2」标记（之后重装模块才生效）
#
#  判读要点：
#    - AUTH 次数：logcat 里 nfc 认证相关行应只出现 1 次（clamp1）
#    - 出现 "Mifare Classic retransmission attempt" 说明还在重传（补丁没生效）
#    - 出现 "MFC maximum retransmission attempts reached" 是正常的放弃路径
#    - tombstone 里仍有 nfc_nci.nqx.default.hw.so 说明还在崩
# =============================================================================

BASE=/data/adb/nfc_mfc_retx_fix
STAGE=$BASE/stage
TARGET=/system/app/NQNfcNci
MOD=/data/adb/modules/nfc_mfc_retx_fix
OUT=/sdcard/nfc_v6
HAL=vendor.nxp.hardware.nfc@1.2-service

log() { echo "$*"; }

need_root() {
  [ "$(id -u 2>/dev/null)" = "0" ] && return 0
  for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su; do
    [ -x "$s" ] && exec "$s" -c "sh $0 $*"
  done
  echo "!! 需要 root"; exit 1
}

status() {
  echo "######## nfc v6 status ########"
  echo "# $(date)  $(getprop ro.build.display.id)"
  echo
  echo "===== 模块 ====="
  if [ -d "$MOD" ]; then
    grep -E '^(name|version)=' "$MOD/module.prop" 2>/dev/null
    echo "disable 标记: $([ -f "$MOD/disable" ] && echo 有（本次开机未加载） || echo 无)"
  else
    echo "模块目录不存在: $MOD"
  fi
  echo "stock_mode  : $([ -f $BASE/stock_mode ] && echo 存在（不干预） || echo 不存在)"
  echo "use_cap2    : $([ -f $BASE/use_cap2 ] && echo 存在 || echo 不存在)"
  echo "auto_reverted: $([ -f $BASE/auto_reverted ] && echo 存在（看门狗回滚过，重启即回原厂） || echo 无)"
  echo "影子库数量  : $(ls $TARGET/lib/arm64 2>/dev/null | wc -l) / 32"
  echo
  echo "===== 影子挂载 ====="
  if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
    echo "挂载: 生效"
  else
    echo "挂载: 未生效"
  fi
  echo "目标 apk : $(ls -l "$TARGET/NQNfcNci.apk" 2>/dev/null | awk '{print $5" "$6" "$7" "$8}')"
  echo "目标 lib : $(ls -l "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | awk '{print $5}') 字节"
  echo "影子 lib : $(ls -l "$STAGE/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | awk '{print $5}') 字节"
  echo "inode 目标/影子: $(ls -i "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | awk '{print $1}') / $(ls -i "$STAGE/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | awk '{print $1}')"
  echo "补丁字节检查（clamp1 应为 1f 01 00 71 / clamp2 应为 1f 05 00 71 / 原厂 1f 11 00 71）:"
  for off in 1668512 1676432 1704468; do
    printf '  off %s: ' "$off"
    od -An -tx1 -j "$off" -N 4 "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | tr -d '\n'
    echo
  done
  echo
  echo "===== 包信息 ====="
  dumpsys package com.android.nfc 2>/dev/null | grep -E 'legacyNativeLibraryDir|primaryCpuAbi|codePath|versionName' | head -6
  echo
  echo "===== 进程 ====="
  NPID=$(pidof com.android.nfc)
  echo "com.android.nfc pid: ${NPID:-none}"
  echo "HAL pid           : $(pidof $HAL)"
  if [ -n "$NPID" ]; then
    echo "--- 已加载 nfc 库 ---"
    grep -E 'libsn100nfc|NQNfcNci' /proc/$NPID/maps 2>/dev/null | awk '{print $6}' | sort -u
  fi
  echo
  echo "===== tombstone ====="
  echo "NFC 相关 tombstone 条数: $(grep -l 'nfc_nci' /data/tombstones/* 2>/dev/null | wc -l)"
  ls -l /data/tombstones 2>/dev/null | tail -3
  echo
  echo "===== 最近的 MFC 日志 ====="
  logcat -b main -d -v time 2>/dev/null | grep -iE 'RwMfc|Mifare|MFC|NfcTagExtns|retransmission' | tail -30
  echo
  echo "===== 模块日志 ====="
  tail -15 "$BASE/nfc_fix.log" 2>/dev/null
}

watch_start() {
  mkdir -p /sdcard 2>/dev/null
  rm -f "$OUT.logcat" "$OUT.dmesg" "$OUT.summary" "$OUT.lc.pid" "$OUT.dm.pid"
  ( logcat -b all -v threadtime 2>/dev/null \
      | grep -iE 'nfc|nq-nci|i2c_geni|GSI QN|NxpNci|phTml|phNxp|RwMfc|Mifare|MFC|NfcTagExtns' \
      >> "$OUT.logcat" ) >/dev/null 2>&1 &
  echo $! > "$OUT.lc.pid"
  (
    N=$(dmesg 2>/dev/null | wc -l)
    while :; do
      M=$(dmesg 2>/dev/null | wc -l)
      if [ "$M" -gt "$N" ]; then dmesg 2>/dev/null | tail -n +$((N+1)) >> "$OUT.dmesg"; N=$M
      elif [ "$M" -lt "$N" ]; then dmesg 2>/dev/null > "$OUT.dmesg"; N=$M; fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  echo $! > "$OUT.dm.pid"
  echo "已开始录制:"
  echo "  logcat -> $OUT.logcat"
  echo "  dmesg  -> $OUT.dmesg"
  echo "现在去贴卡 / 用 NFC Tools 写卡（多试几次，10~20 秒）"
  echo "完事执行: sh $0 watch stop"
}

watch_stop() {
  for f in "$OUT.lc.pid" "$OUT.dm.pid"; do
    [ -f "$f" ] && { p=$(cat "$f" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; pkill -P "$p" 2>/dev/null; rm -f "$f"; }
  done
  pkill -f 'nfc_v6_test.sh' 2>/dev/null
  sleep 1
  {
    echo "######## nfc_v6 summary ########"
    echo "# 时间: $(date)"
    echo "# 设备: $(getprop ro.product.device) / $(getprop ro.build.display.id)"
    echo "# 内核: $(uname -r)"
    echo
    echo "===== 模块状态 ====="
    grep -E '^(name|version)=' "$MOD/module.prop" 2>/dev/null
    echo "影子挂载: $(grep -q " $TARGET " /proc/mounts 2>/dev/null && echo 生效 || echo 未生效)"
    echo "live 补丁字节(0x1975a0): $(od -An -tx1 -j 1668512 -N 4 "$TARGET/lib/arm64/libsn100nfc-nci.so" 2>/dev/null | tr -d '\n')"
    NPID=$(pidof com.android.nfc)
    echo "com.android.nfc pid: ${NPID:-none}"
    [ -n "$NPID" ] && { echo "--- 加载的库 ---"; grep -E 'libsn100nfc' /proc/$NPID/maps 2>/dev/null | awk '{print $6}' | sort -u; }
    echo
    echo "===== 关键计数 ====="
    echo "retransmission attempt 行数 : $(grep -c 'retransmission attempt' "$OUT.logcat" 2>/dev/null)"
    echo "maximum retransmission 行数: $(grep -c 'maximum retransmission' "$OUT.logcat" 2>/dev/null)"
    echo "Mifare/MFC 相关行数         : $(grep -icE 'mifare|MFC' "$OUT.logcat" 2>/dev/null)"
    echo "nfc_write: failed 行数      : $(grep -c 'nfc_write: failed' "$OUT.dmesg" 2>/dev/null)"
    echo "GSI QN err 行数             : $(grep -c 'GSI QN err' "$OUT.dmesg" 2>/dev/null)"
    echo "tombstone(NFC) 条数         : $(grep -l 'nfc_nci' /data/tombstones/* 2>/dev/null | wc -l)"
    echo "nfc 进程重启痕迹            : $(grep -c 'nfc 进程换了 pid' /data/adb/nfc_mfc_retx_fix/nfc_fix.log 2>/dev/null)"
    echo "链接失败(UnsatisfiedLink)   : $(grep -cE 'UnsatisfiedLink|CANNOT LINK EXECUTABLE|dlopen failed' "$OUT.logcat" 2>/dev/null)"
    echo "auto_reverted               : $([ -f /data/adb/nfc_mfc_retx_fix/auto_reverted ] && echo 存在（看门狗已判定失败） || echo 无)"
    echo
    echo "===== MFC/AUTH 相关日志（最多 80 行）====="
    grep -iE 'RwMfc|Mifare|MFC|retransmission|NfcTagExtns|AUTH' "$OUT.logcat" 2>/dev/null | tail -80
    echo
    echo "===== 错误/崩溃相关（最多 60 行）====="
    grep -iE 'abort|crash|FATAL|failed|timeout|busy|deactivat' "$OUT.logcat" 2>/dev/null | tail -60
    echo
    echo "===== dmesg 里 nfc/i2c 行（最多 60 行）====="
    grep -iE 'nfc|nq-nci|i2c_geni|GSI QN' "$OUT.dmesg" 2>/dev/null | tail -60
    echo
    echo "######## 把上面整段发回来 ########"
  } > "$OUT.summary" 2>&1
  echo "摘要已写入: $OUT.summary"
  echo "----- 摘要开始 -----"
  cat "$OUT.summary"
  echo "----- 摘要结束 -----"
}

need_root "$@"
case "$1" in
  status) status ;;
  watch)
    case "$2" in
      start) watch_start ;;
      stop)  watch_stop ;;
      *) echo "用法: sh $0 watch start|stop" ;;
    esac ;;
  stock)
    case "$2" in
      on)  mkdir -p "$BASE"; : > "$BASE/stock_mode"; echo "stock_mode 已创建，重启后回原厂" ;;
      off) rm -f "$BASE/stock_mode"; echo "stock_mode 已删除，重启后启用补丁" ;;
      *) echo "用法: sh $0 stock on|off" ;;
    esac ;;
  cap2) mkdir -p "$BASE"; : > "$BASE/use_cap2"; echo "use_cap2 已创建，重新安装模块后生效" ;;
  *) echo "用法: sh $0 status | watch start|stop | stock on|off | cap2" ;;
esac
