#!/system/bin/sh
# =============================================================================
#  NFC HAL abort() 修复模块  (KernelSU / Magisk / APatch)
#  id: nfc_abort_fix
#
#  目标 : /vendor/lib64/nfc_nci.nqx.default.hw.so
#  崩溃 : signal 6 (SIGABRT) code -1
#         abort+160 <- phNxpNciHal_write_unlocked+1112
#         <- phNxpNciHal_write+276 <- Nfc::write+132 <- _hidl_write
#         <- android.hardware.nfc@1.2 onTransact <- libhidlbase joinThreadPool
#  BuildId : 9edb171e79cb93d44e64f3e7be460440
#
#  ---- 根因（已用反汇编 + 上游源码逐行确认）-------------------------------
#  厂商在该库 0x1D910 处放了 `bl abort`。对照 AOSP/NXP 开源实现
#  （halimpl/pn54x/hal/phNxpNciHal.c 的 phNxpNciHal_write_unlocked），同一位置是：
#
#      } else {                       // p_rx_data != NULL
#          usleep(10000);
#          write_unlocked_status = NFCSTATUS_FAILED;   // <= 上游第 1012 行
#      }
#      ...
#      clean_and_return:
#          phNxpNciHal_cleanup_cb_data(&cb_data);
#          return data_len;
#
#  也就是说厂商把上游的「标记失败后正常返回」替换成了 abort()。
#  触发条件：NFC 芯片 I2C 写连续失败超过 MAX_RETRY_COUNT(5) 次
#  （典型场景就是芯片进入 standby 没及时响应），且 p_rx_data 非 NULL。
#  结果：整个 NFC HAL 进程被杀 -> NFC 服务反复重启 -> NFC 完全不可用。
#
#  ---- 修复 ---------------------------------------------------------------
#  把 0x1D910 的 `bl abort`（4 字节 cf 54 00 94）改成
#  `b 0x1DAE0`（4 字节 e3 ff ff 17）。0x1DAE0 正是上图中
#  "write_unlocked_status = NFCSTATUS_FAILED" 的那两条指令
#  （mov w8,#1 ; strb w8,[x24,#0x380]），随后 b 0x1D96C 进入
#  clean_and_return：释放 CMD 窗口信号量、清 cb_data、校验栈 canary、返回 0。
#
#  只改 4 个字节，ELF 其余部分与 BuildId 完全不变，可与 tombstone 一一对照。
#  上层仍会收到此前已发送的 CORE_RESET_NTF，NFC 协议栈照常自行恢复，
#  只是不再杀进程。
# =============================================================================

MODDIR=${0%/*}
LOG=$MODDIR/nfc_fix.log

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

TARGET=/vendor/lib64/nfc_nci.nqx.default.hw.so
PAYLOAD=$MODDIR/system/vendor/lib64/nfc_nci.nqx.default.hw.so
[ -f "$PAYLOAD" ] || PAYLOAD=$MODDIR/vendor/lib64/nfc_nci.nqx.default.hw.so

EXPECT_BID=9edb171e79cb93d44e64f3e7be460440
EXPECT_PATCH=5f8d0171
EXPECT_STOCK=5f110071
SITE=121104   # 0x1D910

log() { echo "$(date "+%m-%d %H:%M:%S") [service] $*" >> "$LOG"; }

sleep 10

if [ ! -f "$PAYLOAD" ]; then
  log "FATAL payload missing: $PAYLOAD"
  exit 1
fi
if [ ! -f "$TARGET" ]; then
  log "WARN $TARGET not found - nothing to verify (not an NXP SN100 device?)"
  exit 0
fi

DBID=$(od -An -tx1 -j 664 -N 16 "$TARGET" 2>/dev/null | tr -d " \n")
LIVE=$(od -An -tx1 -j $SITE -N 4 "$TARGET" 2>/dev/null | tr -d " \n")
log "live build-id=$DBID site=$LIVE"

if [ "$DBID" != "$EXPECT_BID" ]; then
  log "WARN live library build-id differs from $EXPECT_BID"
  log "     overlay likely did not apply on this ROM; fix INACTIVE."
  exit 0
fi

if [ "$LIVE" = "$EXPECT_PATCH" ]; then
  if grep -F " $TARGET " /proc/self/mountinfo 2>/dev/null | grep -F "nfc_abort_fix" >/dev/null 2>&1; then
    log "RESULT ACTIVE via bind mount (mountless, post-mount.sh) - write retry limit raised 5 -> 100"
  else
    log "RESULT overlay ACTIVE - write retry limit raised 5 -> 100 from the live library"
  fi
elif [ "$LIVE" = "$EXPECT_STOCK" ]; then
  log "RESULT overlay NOT active (library still stock). Reboot once more."
else
  log "RESULT unexpected site bytes $LIVE - inspect manually"
fi

# ---- 重启 NFC HAL，让打过补丁的库被加载 --------------------------------
# 已经在跑的进程仍映射着旧库，必须重启它补丁才立刻生效（否则等下次开机/重连）。
# 本机 init 服务名是 nqnfc_1_2_hal_service
# （见 /vendor/etc/init/vendor.nxp.hardware.nfc@1.2-service.rc，class hal，
#  user/group nfc，lazy 服务，框架会按需拉起）。
HAL_SVC=nqnfc_1_2_hal_service
HAL_BIN=vendor.nxp.hardware.nfc@1.2-service

OLD_PID=$(pidof "$HAL_BIN" 2>/dev/null)
log "current NFC HAL pid=${OLD_PID:-none}"

# init 的服务控制：优先用 /system/bin/stop|start，失败再退回 setprop ctl.*
ctl_stop() {
  if command -v stop >/dev/null 2>&1; then
    stop "$HAL_SVC" 2>/dev/null && return 0
  fi
  /system/bin/setprop ctl.stop "$HAL_SVC" 2>/dev/null
}
ctl_start() {
  if command -v start >/dev/null 2>&1; then
    start "$HAL_SVC" 2>/dev/null && return 0
  fi
  /system/bin/setprop ctl.start "$HAL_SVC" 2>/dev/null
}

if ctl_stop; then
  log "init: stopped $HAL_SVC"
else
  log "init 'stop $HAL_SVC' unavailable; killing the process instead"
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
fi
sleep 2
ctl_start
sleep 3

PID=$(pidof "$HAL_BIN" 2>/dev/null)
if [ -n "$PID" ]; then
  log "NFC HAL running pid=$PID"
  MAP=$(grep nfc_nci.nqx.default.hw.so /proc/$PID/maps 2>/dev/null | head -n 1)
  [ -n "$MAP" ] && log "mapped: $MAP"
else
  log "NFC HAL not up yet - framework starts it on demand (first NFC use / next boot)."
fi

log "=== done ==="
exit 0