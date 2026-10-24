#!/system/bin/sh
# =============================================================================
#  customize.sh —— 由 Magisk / KernelSU / APatch 的安装器 source 执行，
#  在模块文件已解包、默认权限已设置之后运行。
#  这里做三件事：自检载荷、校验设备库版本、修正权限与 SELinux 上下文。
# =============================================================================

ui_print " "
ui_print "======================================"
ui_print " NFC HAL abort() 修复  (nfc_abort_fix)"
ui_print "======================================"
ui_print " "

LIB_REL=system/vendor/lib64/nfc_nci.nqx.default.hw.so
PAYLOAD=$MODPATH/$LIB_REL
TARGET=/vendor/lib64/nfc_nci.nqx.default.hw.so
SITE=121104
EXPECT_PATCH=5f8d0171
EXPECT_BID=9edb171e79cb93d44e64f3e7be460440

if [ ! -f "$PAYLOAD" ]; then
  abort "! 解包后缺少 $LIB_REL —— 压缩包不完整，请重新下载"
fi

# ---- 载荷自检 --------------------------------------------------------------
PSITE=$(od -An -tx1 -j $SITE -N 4 "$PAYLOAD" 2>/dev/null | tr -d ' \n')
PBID=$(od -An -tx1 -j 664 -N 16 "$PAYLOAD" 2>/dev/null | tr -d ' \n')
PSZ=$(stat -c %s "$PAYLOAD" 2>/dev/null)

ui_print "- 载荷大小:   ${PSZ:-?} 字节（应为 254384）"
ui_print "- 载荷 BuildId: $PBID"
ui_print "- 载荷补丁点:   $PSITE（应为 $EXPECT_PATCH）"

[ "$PSITE" = "$EXPECT_PATCH" ] || abort "! 载荷补丁字节异常：$PSITE"
[ "$PBID" = "$EXPECT_BID" ] || abort "! 载荷 BuildId 异常：$PBID"

# ---- 设备库版本校验：版本不一致就拒绝安装 --------------------------------
# 这一点很重要：如果设备上的 NFC HAL 和模块载荷不是同一个 build，
# 覆盖上去会破坏 NFC（甚至拖慢开机），所以宁可装不上也不要装错。
if [ -f "$TARGET" ]; then
  DBID=$(od -An -tx1 -j 664 -N 16 "$TARGET" 2>/dev/null | tr -d ' \n')
  DSITE=$(od -An -tx1 -j $SITE -N 4 "$TARGET" 2>/dev/null | tr -d ' \n')
  ui_print "- 设备 BuildId: $DBID"
  ui_print "- 设备补丁点:   $DSITE"

  if [ -n "$DBID" ] && [ "$DBID" != "$EXPECT_BID" ]; then
    ui_print " "
    ui_print "!! 设备上的 NFC HAL 版本与本模块不匹配："
    ui_print "!!   模块针对 : $EXPECT_BID"
    ui_print "!!   当前设备 : $DBID"
    abort "! 版本不匹配，已拒绝安装（避免把别的 ROM 的库覆盖上来）"
  fi

  if [ "$DSITE" = "$EXPECT_PATCH" ]; then
    ui_print "- 注意: 设备上已是打过补丁的库（可能上一版模块还在生效）"
  fi
else
  ui_print "- 注意: 设备上未找到 $TARGET"
  ui_print "-       本模块只适用于 NXP SN100 的 NFC HAL，仍继续安装"
fi

# ---- 权限与 SELinux 上下文 ------------------------------------------------
# overlay 生效后这些文件会出现在 /vendor/lib64 下，必须带上 vendor_file 标签，
# 否则 nfc HAL 进程会被 SELinux 拒绝打开它（表现为 NFC 直接起不来）。
set_perm "$MODPATH" 0 0 0755
set_perm "$MODPATH/system" 0 0 0755
set_perm "$MODPATH/system/vendor" 0 0 0755
set_perm "$MODPATH/system/vendor/lib64" 0 0 0755
set_perm "$PAYLOAD" 0 0 0644 u:object_r:vendor_file:s0

for f in post-mount.sh post-fs-data.sh service.sh uninstall.sh action.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644

# 初始化日志
: > "$MODPATH/nfc_fix.log" 2>/dev/null
set_perm "$MODPATH/nfc_fix.log" 0 0 0644

# ---- 挂载能力说明 ----------------------------------------------------------
# KernelSU 把「挂载模块 system/ 目录」交给可插拔的 metamodule。没装 metamodule
# 时 system/ 不会被挂载 —— 但本模块自带 post-mount.sh，会在 post-mount 阶段
# 直接 bind mount 那个 .so，所以两种环境都能用：
#   * Magisk / APatch：magic mount 直接覆盖 /vendor（post-mount.sh 会检测到
#     已是补丁字节，跳过 bind）。
#   * KernelSU 无 metamodule：走 post-mount.sh 的 bind mount。
#   * KernelSU 有 metamodule：overlay 生效，post-mount.sh 同样跳过。
if [ -n "$KSU" ] || [ -d /data/adb/ksu ]; then
  ui_print "- KernelSU 环境：已自带 mountless 兜底（post-mount.sh bind mount）"
  if [ -d /data/adb/metamodule ]; then
    ui_print "- 检测到 metamodule: $(readlink -f /data/adb/metamodule 2>/dev/null | xargs -r basename)"
    ui_print "  将走 overlay 挂载路径，post-mount.sh 自动跳过 bind。"
  else
    ui_print "- 未检测到 metamodule：将使用 post-mount.sh 直接 bind mount，"
    ui_print "  不需要额外安装 meta-overlayfs。"
  fi
fi

ui_print " "
ui_print "- 已安装到: $MODPATH"
ui_print "- 重启后生效；原始 /vendor 分区不会被修改"
ui_print "- 卸载模块即可完全还原"
ui_print " "
