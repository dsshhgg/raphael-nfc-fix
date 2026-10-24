#!/system/bin/sh
# post-fs-data: 早期阶段只能做「记录 + 载荷自检」，此时 /vendor 还没 overlay，
# 所以这里不判断 overlay 是否生效，也不重启服务。
MODDIR=${0%/*}
LOG=$MODDIR/nfc_fix.log

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

PAYLOAD=$MODDIR/system/vendor/lib64/nfc_nci.nqx.default.hw.so
# KernelSU 安装器可能把 system/vendor 搬成 $MODDIR/vendor（见 post-mount.sh 注释）
[ -f "$PAYLOAD" ] || PAYLOAD=$MODDIR/vendor/lib64/nfc_nci.nqx.default.hw.so
SITE=121104   # 0x1D910
EXPECT_PATCH=5f8d0171
EXPECT_BID=9edb171e79cb93d44e64f3e7be460440

log() { echo "$(date "+%m-%d %H:%M:%S") [post-fs-data] $*" >> "$LOG"; }

if [ -f "$LOG" ]; then
  tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

if [ ! -f "$PAYLOAD" ]; then
  log "FATAL payload missing: $PAYLOAD"
  exit 1
fi

PSITE=$(od -An -tx1 -j $SITE -N 4 "$PAYLOAD" 2>/dev/null | tr -d " \n")
PBID=$(od -An -tx1 -j 664 -N 16 "$PAYLOAD" 2>/dev/null | tr -d " \n")

if [ "$PSITE" != "$EXPECT_PATCH" ]; then
  log "FATAL payload corrupt: site=$PSITE want=$EXPECT_PATCH"
  exit 1
fi
if [ "$PBID" != "$EXPECT_BID" ]; then
  log "WARN payload build-id=$PBID (expected $EXPECT_BID)"
fi

chmod 0644 "$PAYLOAD" 2>/dev/null
chown 0:0 "$PAYLOAD" 2>/dev/null
chcon u:object_r:vendor_file:s0 "$PAYLOAD" 2>/dev/null

log "payload OK build-id=$PBID site=$PSITE -> overlay staged"
exit 0