# raphael-nfc-fix

红米 K20 Pro（`raphael` / SM8150）+ **HyperOS 4** 上「贴加密卡/手环卡就崩、之后 NFC 开关消失、卡也写不了」的完整修复集：
根因分析文档 + 3 个 Magisk / KernelSU 模块 + 字节级补丁工具 + 设备侧取证脚本。

- 设备：Redmi K20 Pro，`OS4.0.0.16.XPCCNXM` / `CP2A.260605.016`（Android 17）
- 内核：`4.14.357-Zundamon-Evo-v20260827-1`（NFC 崩溃与内核无关，见下）
- 芯片：NXP SN100 / PN553，`nq-nci` 走 `qupv3_se9_i2c`（`a84000.i2c`）

---

## 一句话结论

HyperOS 4 把 `libsn100nfc-nci.so` 从 **MW10**（781,960 B）换成了 **MW15**（2,034,440 B），
新版本多了「MIFARE Classic 重传」：认证失败会**连发最多 5 次 AUTH**，把 PN553 的 I2C 从机拖死，
HAL 写事务重试耗尽后 `abort()` 自杀。HyperOS 2 没有这段代码，所以同样的 vendor 栈一切正常。

```
HOS2（MW10）：认证失败 → 放弃 → 卡留在场上 → App 自己认证 → 读写正常
HOS4（MW15）：
   (A) 认证失败 → 连发 AUTH 最多 5 次 → PN553 I2C 挂死 → HAL abort()      ★ 崩溃
   (B) 若关掉 MIFARE reader → 小米 NfcTagExtns 判成「非标卡」→ 秒退      ★ 写卡失败
```

两个症状是同一段新代码的两个分支，所以「关掉 MIFARE reader」只能救崩溃、救不了写卡。
完整取证与反汇编见 [docs/root-cause-hyperos2-vs-hyperos4.md](docs/root-cause-hyperos2-vs-hyperos4.md)。

## 三个模块

| 模块 | 机制 | 代价 | 建议 |
|---|---|---|---|
| [`mfc-retx-fix-v6.1`](docs/module-mfc-retx-fix-v6.1.md) | 把 MW15 的 5 处 `cmp #4` 钳到 `cmp #0`（只试 1 次），用「影子 nativeLibraryDir」加载补丁库 | 依赖 `nativeLibraryDir` 机制；首次认证失败会直接放弃（再贴一次即可） | **首选**：不崩 + 能写 |
| [`abort-fix-v3`](docs/module-abort-fix-v3.md) | 把 HAL 写事务重试上限 5 次（≈50 ms）提到 100 次（≈1 s），只改 1 个立即数字节 | 只加宽容忍窗口，不阻止 AUTH 连发；芯片真死时仍会 abort 自愈 | 偶发 abort、能读但写卡崩的场合 |
| [`mifare-config-v5`](docs/module-mifare-config-v5.md) | `libnfc-nxp.conf` 里 `MIFARE_READER_ENABLE=0x00`，从源头去掉 AUTH | **加密卡彻底用不了**（退化成 NfcA），NTAG 不受影响 | 只求不崩、不写加密卡时 |

> v5 与 v6 **互斥**：v5 的 conf 覆盖会让小米 `NfcTagExtns` 把卡判成非标卡秒退，装了 v6 也写不了。
> 装 v6 之前先卸载/停用 v5。

## 目录

```
docs/                            根因报告与各模块说明
  root-cause-hyperos2-vs-hyperos4.md
  module-abort-fix-v3.md
  module-mfc-retx-fix-v6.1.md
  module-mifare-config-v5.md
modules/
  abort-fix-v3/                  HAL 重试上限（含补丁后的 nfc_nci.nqx.default.hw.so）
  mfc-retx-fix-v6.1/             MFC 重传钳制（含 32 个原生库 + clamp1/clamp2 两份补丁库）
  mifare-config-v5/              关闭 MIFARE reader（含改好的 libnfc-nxp.conf）
tools/
  patch_hal_retry.py             从你 ROM 里的原厂 HAL 复现 v3 的载荷
  patch_mfc_retx.py              从你 APK 里的原厂库复现 v6 的 clamp1/clamp2
  verify_payload.py              发布前校验仓库里所有载荷的大小/sha256/关键字节
scripts/                         设备侧只读取证脚本（见下）
```

## 安装

三个模块都是标准的 Magisk / KernelSU / APatch 模块 zip——**仓库里放的是模块源文件**，
需要打包时把对应 `modules/*` 目录压成 zip（`META-INF/com/google/android/update-binary`
已在目录里，`customize.sh` 会做机型与版本校验）：

```sh
cd modules/mfc-retx-fix-v6.1 && zip -r ../../nfc_mfc_retx_fix.zip .
```

也可以在 GitHub Releases 里下载打包好的 zip。装完重启；`/vendor`、`/system` 分区都不会被改写。

## 从自己的 ROM 复现载荷（不想用别人造的库时）

```sh
# 1) HAL 重试上限（v3）
python tools/patch_hal_retry.py /path/to/nfc_nci.nqx.default.hw.so -o nfc_nci.patched.so
python tools/patch_hal_retry.py --verify nfc_nci.patched.so

# 2) MFC 重传钳制（v6）
python tools/patch_mfc_retx.py /path/to/libsn100nfc-nci.so --mode clamp1 -o libsn100.clamp1.so
python tools/patch_mfc_retx.py --verify libsn100.clamp1.so

# 3) 发布前总校验
python tools/verify_payload.py
```

两个脚本都会校验文件大小与已知哈希/BuildId，**补丁点字节不是预期值就拒绝盲改**；
脚本里的 `cmp wN, #imm` 机器码由公式生成并有断言自检，可核对
`1f 11 00 71`（cmp #4）→ `1f 01 00 71`（cmp #0）、`5f 11 00 71` → `5f 8d 01 71`（cmp #99）。

## 验证

```sh
# v3：HAL 上是否为补丁字节（5f 8d 01 71 = 生效）
adb shell su -c "od -An -tx1 -j 121104 -N 4 /vendor/lib64/nfc_nci.nqx.default.hw.so"

# v6：进程是否从影子目录加载补丁库
adb shell su -c "grep NQNfcNci /proc/\$(pidof com.android.nfc)/maps"

# v6：贴卡时不应再出现 "Mifare Classic retransmission attempt"
adb shell su -c "logcat -d | grep -iE 'retransmission|rw_mfc|AUTH'"
```

## 回滚

| 模块 | 立刻回原厂 |
|---|---|
| abort-fix-v3 | `touch /data/adb/modules/nfc_abort_fix/disable`（重启生效） |
| mfc-retx-fix-v6.1 | `touch /data/adb/nfc_mfc_retx_fix/stock_mode`（重启生效）；看门狗 `auto_reverted` 会自动回滚 |
| mifare-config-v5 | `touch /data/adb/nfc_mifare_safe/stock_mode`（重启生效） |

## 设备侧取证脚本

放在手机 `/sdcard/` 下以 root 跑，全部只读（不改分区、不重启服务）：

| 脚本 | 用途 |
|---|---|
| `nfc_state.sh` | NFC 开关消失/适配器状态取证；`off`/`on` 一键给模块打 `disable` 标记 |
| `nfc_diag.sh` | `com.android.nfc` ANR / 启动失败第一轮取证 |
| `nfc_diag2.sh` | 第二轮：开机就没 I2C 响应这条线索（tombstone、GPI-QUP 初始化、固件） |
| `nfc_diag3.sh` | 芯片「不应答」的复位重试 + 取证（GPIO 状态、I2C 总线上有哪些设备） |
| `nfc_writewatch.sh` | `start`/`stop` 抓写卡那一瞬的 dmesg + logcat，输出摘要 |
| `nfc_v6_test.sh` | 验证 v6 模块是否真生效：`status` / `watch start\|stop` / `stock on\|off` / `cap2` |

## 声明

- `modules/` 里的 `.so` 与 `libnfc-nxp.conf` 是**原厂私有库的补丁副本**（NXP / Qualcomm / 小米），
  仅作为本机维修与研究用途存档；版权归各自权利人，不适用本仓库任何开源许可。
- 三个模块都只做**内存/overlay 层覆盖**，从不写 `/vendor`、`/system` 分区；卸载即还原。
- 修改 HAL / 框架库存在把设备 NV 或 I2C 外设搞到需要重启的风险，自担。
