#!/system/bin/sh
# 开机后：确认影子挂载状态 + 看门狗。
#
# 看门狗逻辑：如果 com.android.nfc 在开机后 90 秒内重启了 3 次以上，
# 说明影子库这套方案在这台机器上没跑通 —— 立刻写 auto_reverted 标记，
# 这样「下次重启」就会自动不挂载、回到原厂（不用进 recovery、不用手忙脚乱）。
PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

MODDIR=${0%/*}
BASE=/data/adb/nfc_mfc_retx_fix
STAGE=$BASE/stage
TARGET=/system/app/NQNfcNci
LOG=$BASE/nfc_fix.log
mkdir -p "$BASE" 2>/dev/null
exec >>"$LOG" 2>&1
echo "--- $(date '+%F %T') service.sh (v6.1) ---"

if [ -f "$BASE/stock_mode" ]; then
  echo "stock_mode 存在，跳过"
  exit 0
fi
if [ -f "$BASE/auto_reverted" ]; then
  echo "auto_reverted 存在，跳过"
  exit 0
fi

# post-fs-data 没挂上就补挂一次
if ! grep -q " $TARGET " /proc/mounts 2>/dev/null; then
  echo "post-fs-data 没挂上，这里补挂"
  mount -o bind "$STAGE" "$TARGET" 2>/dev/null || mount --bind "$STAGE" "$TARGET" 2>/dev/null
fi
if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
  echo "挂载状态: OK ($(ls "$TARGET/lib/arm64" 2>/dev/null | wc -l) 个库)"
else
  echo "挂载状态: FAILED（本次不生效）"
  exit 0
fi

NPID=$(pidof com.android.nfc)
echo "com.android.nfc pid: ${NPID:-none}"
echo "HAL pid: $(pidof vendor.nxp.hardware.nfc@1.2-service)"

# 记录进程里实际加载的库
if [ -n "$NPID" ]; then
  echo "--- maps 里的 nfc 库 ---"
  grep -E 'libsn100nfc' /proc/$NPID/maps 2>/dev/null | awk '{print $6}' | sort -u
fi

# ---- 看门狗：90 秒内 3 次重启即判定失败 ----
i=0
bad=0
last=$NPID
while [ $i -lt 30 ]; do
  sleep 3
  i=$((i+1))
  p=$(pidof com.android.nfc)
  if [ -z "$p" ]; then
    [ -n "$last" ] && { bad=$((bad+1)); echo "  $(date '+%T') nfc 进程消失（第 $bad 次）"; last=; }
  else
    if [ "$p" != "$last" ]; then
      [ -n "$last" ] && { bad=$((bad+1)); echo "  $(date '+%T') nfc 进程换了 pid（第 $bad 次）: $last -> $p"; }
      last=$p
    fi
  fi
  if [ $bad -ge 3 ]; then
    echo "!!! com.android.nfc 反复重启 $bad 次 —— 判定影子库方案失败"
    echo "!!! 已写 auto_reverted 标记；重启一次即自动回原厂"
    : > "$BASE/auto_reverted"
    echo "--- 最近 40 行 NFC 相关 logcat ---"
    logcat -b all -d 2>/dev/null | grep -iE 'nfc|dlopen|UnsatisfiedLink|CANNOT LINK|library' | tail -40
    echo "--- 最近 tombstone ---"
    ls -lt /data/tombstones 2>/dev/null | head -5
    break
  fi
done
echo "看门狗结束（重启次数 $bad）"
echo "--- $(date '+%F %T') service.sh 完成 ---"
exit 0
