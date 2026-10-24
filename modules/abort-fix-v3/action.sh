#!/system/bin/sh
# action.sh —— 在 KernelSU / Magisk 管理器里点“执行”按钮时运行。
# 作用：现场报告补丁是否真的生效，不用去翻日志。

MODDIR=${0%/*}
# 管理器里跑脚本时 PATH 可能很短，od/pidof/grep/tail 都来自 toybox。
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH
TARGET=/vendor/lib64/nfc_nci.nqx.default.hw.so
SITE=121104
EXPECT_PATCH=5f8d0171
EXPECT_STOCK=5f110071
EXPECT_BID=9edb171e79cb93d44e64f3e7be460440

echo "==== nfc_abort_fix 状态 ===="
echo

if [ ! -f "$TARGET" ]; then
  echo "未找到 $TARGET"
  echo "本模块只适用于 NXP SN100 NFC HAL，当前设备可能不匹配。"
  exit 0
fi

DBID=$(od -An -tx1 -j 664 -N 16 "$TARGET" 2>/dev/null | tr -d ' \n')
LIVE=$(od -An -tx1 -j $SITE -N 4 "$TARGET" 2>/dev/null | tr -d ' \n')

echo "库文件  : $TARGET"
echo "BuildId : $DBID"
echo "补丁点  : $LIVE"
echo

if [ "$DBID" != "$EXPECT_BID" ]; then
  echo "结果: 版本不匹配"
  echo "      本模块针对 $EXPECT_BID"
  echo "      当前设备是 $DBID"
  echo "      overlay 没有生效，或这台机器的 NFC HAL 版本不同。"
elif [ "$LIVE" = "$EXPECT_PATCH" ]; then
  echo "结果: 补丁已生效 (OK)"
  echo "      abort() 已被替换成失败清理分支，NFC 写失败时不再杀进程。"
elif [ "$LIVE" = "$EXPECT_STOCK" ]; then
  echo "结果: 补丁未生效"
  echo "      当前仍是原始字节 $EXPECT_STOCK。"
  echo "      常见原因：安装后还没重启（post-mount 阶段才会挂载）。"
  echo "      若已重启仍是这样，看一下上面日志里 post-mount 那几行："
  echo "        tail -n 40 $MODDIR/nfc_fix.log"
else
  echo "结果: 补丁点字节异常 ($LIVE)"
  echo "      可能被其他模块覆盖，请检查。"
fi

echo
echo "挂载方式:"
if grep -F " $TARGET " /proc/self/mountinfo 2>/dev/null | grep -F "nfc_abort_fix" >/dev/null 2>&1; then
  echo "  bind mount (mountless, post-mount.sh)"
elif grep -F " $TARGET " /proc/self/mountinfo 2>/dev/null | grep -qE "overlay|mountify|myoverlayfs"; then
  echo "  overlay (metamodule)"
else
  echo "  无（当前显示的就是 /vendor 分区里的原始文件）"
fi

echo
PID=$(pidof vendor.nxp.hardware.nfc@1.2-service 2>/dev/null)
if [ -n "$PID" ]; then
  echo "NFC HAL 进程 pid=$PID"
  grep nfc_nci.nqx.default.hw.so /proc/$PID/maps 2>/dev/null | head -n 1
else
  echo "NFC HAL 当前未运行（框架会在用到 NFC 时拉起）"
fi

echo
echo "最近日志: $MODDIR/nfc_fix.log"
tail -n 20 "$MODDIR/nfc_fix.log" 2>/dev/null
