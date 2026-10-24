#!/system/bin/sh
# =============================================================================
#  post-mount.sh —— KernelSU 的 post-mount 阶段（普通模块也会执行，不需要 metamodule）
#
#  为什么需要这个脚本：
#    KernelSU 把「挂载模块的 system/ 目录」这件事交给可插拔的 metamodule。
#    没装 metamodule 时，本模块里的 system/vendor/lib64/*.so 根本不会被挂载，
#    补丁自然不会生效。而 metamodule 动辄几百 KB 到几 MB，还要额外重启流程。
#
#    这个脚本提供「Mountless」路径：直接把模块目录里的库文件 bind mount 到
#    /vendor/lib64/ 的同一个文件名上。内核允许在只读分区上 bind mount，
#    不会改动分区内容，重启即消失。
#
#  执行顺序保证（KernelSU userspace/ksud/src/init_event.rs:120）：
#    post-fs-data 阶段 -> 加载 sepolicy -> 执行 metamodule 的 mount 脚本
#    -> run_stage("post-mount") -> 普通模块的 post-mount.sh   ← 本文件
#    之后才是 zygote-start / class_start hal，所以 NFC HAL 起来时补丁已在位。
#
#  两种世界都要兼容：
#    1) 装了 metamodule（meta-overlayfs / mountify）→ /vendor 上已经是补丁版本，
#       这里检测到补丁字节就直接退出，不做多余挂载。
#    2) 没装 metamodule → 检测到原始字节，做 bind mount。
# =============================================================================

MODDIR=${0%/*}
LOG=$MODDIR/nfc_fix.log

# init 里跑脚本时 PATH 可能不含 /system/bin（不同 ROM 的 init 环境不一样），
# 而下面要用 od / mount / chcon / grep / awk / date，全部来自 toybox。
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

TARGET=/vendor/lib64/nfc_nci.nqx.default.hw.so
PAYLOAD=$MODDIR/system/vendor/lib64/nfc_nci.nqx.default.hw.so

# KernelSU 的安装器（userspace/ksud/src/installer.sh:339-354 handle_partition）
# 在 /vendor 是真实挂载点（而非符号链接）时，会把模块里的 system/vendor 搬到
# $MODDIR/vendor，再留一个 system/vendor -> ../vendor 的符号链接。
# 正常情况两条路径等价（符号链接会解析过去），但为了不受该行为影响，
# 这里显式兜底：符号链接路径读不到就试真实路径。
if [ ! -f "$PAYLOAD" ] && [ -f "$MODDIR/vendor/lib64/nfc_nci.nqx.default.hw.so" ]; then
  PAYLOAD=$MODDIR/vendor/lib64/nfc_nci.nqx.default.hw.so
fi

SITE=121104                       # 0x1D910
EXPECT_PATCH=5f8d0171             # cmp w10,#99 (重试上限)
EXPECT_STOCK=5f110071             # cmp w10,#4
EXPECT_BID=9edb171e79cb93d44e64f3e7be460440
VENDOR_CON="u:object_r:vendor_file:s0"

log() { echo "$(date "+%m-%d %H:%M:%S") [post-mount] $*" >> "$LOG"; }

log "=== post-mount start ==="

# ---- 载荷自检 --------------------------------------------------------------
if [ ! -f "$PAYLOAD" ]; then
  log "FATAL payload missing: $PAYLOAD"
  exit 0
fi
PSITE=$(od -An -tx1 -j $SITE -N 4 "$PAYLOAD" 2>/dev/null | tr -d ' \n')
if [ "$PSITE" != "$EXPECT_PATCH" ]; then
  log "FATAL payload site=$PSITE want=$EXPECT_PATCH (refusing to mount a corrupt payload)"
  exit 0
fi

# ---- 目标是否存在于本设备 ------------------------------------------------
if [ ! -f "$TARGET" ]; then
  log "WARN $TARGET not found - not an NXP SN100 device? nothing to do"
  exit 0
fi

LIVE=$(od -An -tx1 -j $SITE -N 4 "$TARGET" 2>/dev/null | tr -d ' \n')
LIVE_BID=$(od -An -tx1 -j 664 -N 16 "$TARGET" 2>/dev/null | tr -d ' \n')
log "live build-id=$LIVE_BID site=$LIVE"

if [ "$LIVE" = "$EXPECT_PATCH" ]; then
  log "overlay already active (metamodule path) - skip bind mount"
  exit 0
fi

if [ "$LIVE" != "$EXPECT_STOCK" ]; then
  log "unexpected live site bytes $LIVE - skip (check for a conflicting module)"
  exit 0
fi

# ---- 版本护栏：build-id 不一致就绝不挂 -----------------------------------
# 挂上去就会让 HAL 加载一个 ABI 不匹配的库，比不修更糟（可能直接起不来）。
if [ "$LIVE_BID" != "$EXPECT_BID" ]; then
  log "FATAL live build-id $LIVE_BID != $EXPECT_BID - refusing to bind (wrong ROM/library build)"
  exit 0
fi

# ---- 干净地重做：先拆掉上一次可能留下的 same-file bind ----------------------
# 只有确认这个 mountpoint 的来源是我们自己的模块目录时才 umount，
# 避免误拆别的模块/系统的挂载。
if grep -F " $TARGET " /proc/self/mountinfo 2>/dev/null | grep -F "nfc_abort_fix" >/dev/null 2>&1; then
  umount "$TARGET" 2>/dev/null && log "removed previous bind mount"
fi

# ---- SELinux 上下文 --------------------------------------------------------
# bind mount 保留的是源 inode 的标签。HAL 进程（hal_nfc 域）需要能读
# vendor_file 类型的文件，所以必须把载荷标成和 /vendor 下原文件一致。
CURCON=$(ls -Zd "$PAYLOAD" 2>/dev/null | awk '{print $1}')
if [ "$CURCON" != "$VENDOR_CON" ]; then
  chcon "$VENDOR_CON" "$PAYLOAD" 2>/dev/null || \
    busybox chcon "$VENDOR_CON" "$PAYLOAD" 2>/dev/null
  CURCON=$(ls -Zd "$PAYLOAD" 2>/dev/null | awk '{print $1}')
fi
log "payload context=${CURCON:-unknown}"

# ---- bind mount ------------------------------------------------------------
if mount -o bind "$PAYLOAD" "$TARGET" 2>/dev/null; then
  NOW=$(od -An -tx1 -j $SITE -N 4 "$TARGET" 2>/dev/null | tr -d ' \n')
  if [ "$NOW" = "$EXPECT_PATCH" ]; then
    log "RESULT bind mount OK - live library is now patched (mountless mode)"
  else
    log "ERROR bind mount reported success but site reads $NOW"
  fi
else
  log "ERROR bind mount failed: $PAYLOAD -> $TARGET"
  log "      fall back to installing a metamodule (meta-overlayfs / mountify)"
fi

log "=== post-mount done ==="
exit 0
