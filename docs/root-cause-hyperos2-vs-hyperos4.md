# 澎湃2 vs 澎湃4 NFC 栈深度解包报告（Redmi K20 Pro / raphael）

时间：2026-10-23　设备：HyperOS 4.0.0.16（Android 17）、KernelSU、内核 4.14.357-Zundamon-Evo
目标：解释「为什么澎湃2 上贴加密卡/手环卡完全正常，澎湃4 上一贴就崩、而且写不了卡」
约束：不动内核、不改 vendor 分区、不重签 APK

---

## 1. 先排除 vendor 侧：四个关键文件逐字节相同

拿澎湃2（Raphael_HyperOS2_R8.7）和澎湃4（Raphael_HyperOS4.0.0.16）的镜像各自解出同一条链路：

| 文件 | HOS2 | HOS4 | SHA256 |
|---|---|---|---|
| `/vendor/bin/hw/vendor.nxp.hardware.nfc@1.2-service` | 41,008 | 41,008 | **相同** |
| `/vendor/etc/libnfc-nxp.conf` | 15,823 | 15,823 | **相同**（逐行 diff 也一致） |
| `/vendor/lib64/nfc_nci.nqx.default.hw.so` | 254,384 | 254,384 | **相同** |
| `/vendor/lib64/libsn100u_fw.so` | 207,554 | 207,554 | **相同** |

→ HAL、HAL 配置、NFC 芯片固件、vendor service 全都没有变化。
**崩溃和写卡失败都不可能来自 vendor 侧**，只能是 system 侧的框架库/APK（或内核时序）。

## 2. 真正的差异：`/system/app/NQNfcNci` 里的两个框架库

| | HOS2 | HOS4 |
|---|---|---|
| `libsn100nfc-nci.so` | 781,960 B | 2,034,440 B |
| 构建路径字符串 | `.../libnfc-nci/MW10.00.08/SN100x` | `.../libnfc-nci/mw15_0B/SN100x` |
| 附带 UBSan | 无 | 捆了 `libclang_rt.ubsan_standalone-aarch64-android.so`(926KB) |
| `libsn100nfc_nci_jni.so` | 820,680 B | 1,894,648 B |
| 小米 `NfcTagExtns` 类 | **不存在** | **存在** |
| MIFARE Classic 重传 | **不存在**（没有相关字符串/代码） | **存在**，上限 5 次 |

### 2.1 HOS4 独有的 MW15 行为：`MIFARE Classic 重传`

HOS4 的 `libsn100nfc-nci.so` 里新增了这些字符串，HOS2 里一个都没有：

```
Mifare Classic retransmission attempt          (.rodata 0x622b3)
MFC maximum retransmission attempts reached    (.rodata 0x5970b)
MIFARE Detected First Time  Resume the Polling Loop
MIFARE Not Detected  Giving Priority for other Technology
MIFARE Detected TimerExpired, Final Notifying the Event
MiBeam_Timer_timeout MIFARE Not Discovered!!
rw_mfc_handle_write_rsp / rw_mfc_formatBlock / rw_mfc_writeBlock / RW_MfcWriteNDef / RW_MfcFormatNDef
```

（HOS2 只有 `RW_MfcReadNDef` / `RW_MfcDetectNDef` / `rw_mfc_readBlock` / `rw_mfc_authenticate`。）

反汇编出来是一个统一的重传循环，重传计数放在全局 RW 控制块 `[x23+0x200]`
（`x23 = *(0x1df000+0xea0)`）：

```
0x197594  ldr  w8, [x23, #0x200]   ; 当前重传次数
0x1975a0  cmp  w8, #4              ; ★ 上限 5 次（0..4）
0x1975a4  b.hi 0x197618            ; 超限 -> 日志 "MFC maximum retransmission attempts reached" -> 放弃
0x1975b0  add  w8, w8, #1
0x1975bc  str  w8, [x23, #0x200]
0x1975c8 ... bl 0x1d2c58           ; 重新下发（再发一次 AUTH）
```

同样的结构一共 **5 处**（读路径 / 写路径 / MiBeam 状态机各一套）：

| 文件偏移 | 指令 | 配对 |
|---|---|---|
| 0x1975a0 | `cmp w8,#4` | 数据缓冲 `[x23+0xc0]` |
| 0x199490 | `cmp w8,#4` | 数据缓冲 `[x23+0xa0]` |
| 0x1a0214 | `cmp w8,#4` | 数据缓冲 `[x23+0x40]` |
| 0x1a7204 | `cmp w8,#4` | MiBeam 超时路径 |
| 0x1a736c | `cmp w9,#4` | MiBeam 状态机 |

计数在命令成功后被清零（`0x1989ec`、`0x19f68c` 处 `str wzr,[x23,#0x200]`）。

**这正是 tombstone 里「连试 4 次 AUTH 后 I2C 挂死 → abort」的代码来源**：
澎湃2 的 MW10 认证失败一次就放弃（卡还留在场上，App 自己认证就能读写）；
澎湃4 的 MW15 失败后立刻重发，5 次连发把 PN553 的 I2C 拖死：

```
nq-nci 2-0028: nfc_write: failed to write after 3 retries
i2c_geni a84000.i2c: GSI QN err:0x0, status:0x4d3, err:2
NxpHal: write_unlocked failed - PN54X Maybe in Standby Mode (max count = 0x5)
→ abort()  #01 0x1db54 nfc_nci.nqx.default.hw.so phNxpNciHal_write_unlocked+1112
```

### 2.2 小米在 HOS4 加的 `NfcTagExtns`：关掉 MIFARE reader 后「能看卡号但写不了」

在 `libsn100nfc_nci_jni.so`（HOS2 没有这个类）里：

| 符号 | 地址 | 大小 |
|---|---|---|
| `NfcTagExtns::processNonStdTagOperation(TAG_API_REQUEST,TAG_OPERATION)` | 0x13dbdc | 652 |
| `NfcTagExtns::performTagDeactivation()` | 0x13e198 | 1148 |
| `NfcTagExtns::isNonStdMFCTagDetected()` | 0x1409f0 | 16 |
| `NfcTagExtns::processMfcTransFailed()` | 0x13ece8 | 396 |
| `NfcTagExtns::updateNonStdTagState(u8,u8)` | 0x140278 | 752 |
| `NfcTagExtns::storeNonStdTagData()` | 0x14079c | — |
| `NfcTag::isNfcForumT2T()` | 0x13b920 | 636 |

`isNonStdMFCTagDetected` 整个函数就是读状态字的 bit1：
`ldrb w8,[x0,#0x12c]; ubfx w0,w8,#1,#1; ret`

调用链：`processActivatedNtf` → `updateNonStdTagState` → 判成非标卡 → `storeNonStdTagData`
→ `processNonStdTagOperation`（在 JNI 的 connect/transceive 等 8 处被调用）
→ `performTagDeactivation`（`5000` HLTA + `21060101`），约 135 ms 一轮。
App 侧表现为 Tag lost → 「编写错误」，抓包证实 **一条 A2 写指令都没发出去**。

### 2.3 顺带澄清一个旧结论

`libsn100nfc-nci.so` `.data` 里的 `KeyNDEF`(0x1e6e10) / `KeyMAD`(0x1e6e16) /
`KeyDefault`(0x1e6e1c) 不是「随便拿默认钥匙试」的密钥表，而是 NXP 的
**MAD/NDEF 目录标准密钥**（`d3f7d3f7d3f7` / `a0a1a2a3a4a5` / `ffffffffffff`），
用在 `RW_MfcDetectNDef` 里读 MAD 目录。HOS2 的库里这两个常量根本不存在。
所以「改密钥表」不是正路（只对恰好用这三把钥匙的卡有效）。

---

## 3. 因果链（结论）

```
HOS2（MW10）：认证失败 → 放弃 → 卡留在场上 → App 自己认证 → 读写正常
HOS4（MW15）：
   (A) 认证失败 → 重传最多 5 次 → 连发 AUTH → PN553 I2C 挂死 → HAL abort  ★崩溃
   (B) 若关掉 MIFARE reader → 小米 NfcTagExtns 判成「非标卡」→ 秒退 → 写不了  ★写卡失败
```

两个症状是同一段新代码的两个分支，所以「关 MIFARE reader」（v5 模块）只能救崩溃、救不了写卡。

## 4. 修复方案（已产出成品）

### 方案 R（本报告主张）：钳制重传，等于把 MW15 拉回 MW10 的行为

5 处 `cmp wN,#4` → `cmp wN,#0`，每处改 1 个立即数（文件偏移 +1 那一字节 0x11→0x01），
不改大小、不改结构、不动依赖：

- 原厂库 sha256 `13387c9ade4f01c9a0f5e0d4dc2337da30704eddd7d9b9631e245f2e329365f9`
- clamp1（只试 1 次）`54cadcd30b1509eb918795e8c2bff23db8ad80e6b630fc62e048a6b8f575864e`
- clamp2（最多 2 次）`711a78daff1f5b90afe8296ad099d33299d4cdef0b29199cde13332d9087c0dc`

装载方式：**影子库**。`dumpsys package com.android.nfc` 的
`legacyNativeLibraryDir=/system/app/NQNfcNci/lib`，而原厂该目录不存在（只有 APK）——
把「原厂 APK + `lib/arm64/libsn100nfc-nci.so`」放进影子目录 bind 挂到
`/system/app/NQNfcNci`，nativeloader 就优先加载这份，完全绕开 APK 签名
（上一轮实测这条路径确实被 `com.android.nfc` 加载了）。
成品：`nfc_mfc_retx_fix.zip`（v6.0-beta1）。

### 备选（若 R 不够）
- 方案 N：`isNonStdMFCTagDetected` @0x1409f0 → `mov w0,#0; ret`（让非标卡不被秒退）
- 方案 T：`NfcTag::isNfcForumT2T` @0x13b920 → `mov w0,#1; ret`（已生成 patched 产物）
- 方案 D：`performTagDeactivation` @0x13e198 直接 ret
- 方案 K：改 KeyNDEF/KeyMAD/KeyDefault（只对用标准钥匙的卡有用，不推荐）

## 5. 待验证（手机连上后）

1. 影子挂载是否生效：`grep NQNfcNci /proc/$(pidof com.android.nfc)/maps`
2. 贴卡时 logcat 里 AUTH 只出现 1 次、不再出现 `Mifare Classic retransmission attempt`
3. `/data/tombstones` 不再新增 NFC 记录
4. NFC Tools 写卡时抓包能看到 `A2` 写指令真的发出去
5. 若 clamp1 太激进（真卡第一次没认到就放弃）→ 换 clamp2

## 6. 补记：v6.0 装完后 `com.android.nfc` 反复崩溃的真正原因

v6.0 只把 `libsn100nfc-nci.so` 一个文件放进影子目录的 `lib/arm64/`，结果开机后
`com.android.nfc` 崩个不停。查清后原因很清晰：

原厂 `NQNfcNci.apk` 里**自带整套 32 个原生库**：

```
lib/arm64-v8a/libsn100nfc-nci.so            2,034,440
lib/arm64-v8a/libsn100nfc_nci_jni.so        1,894,648
lib/arm64-v8a/libclang_rt.ubsan_standalone-aarch64-android.so  926,016
lib/arm64-v8a/libbase.so / libc++.so / libbinder.so / libchrome.so
lib/arm64-v8a/libhidlbase.so / libutils.so / libunwindstack.so
lib/arm64-v8a/libsn100u 相关 HIDL: android.hardware.nfc@1.x / vendor.nxp.hardware.nfc@x
lib/arm64-v8a/ld-android.so / libdl_android.so / libevent.so ...
```

原厂 `/system/app/NQNfcNci/` 下**没有 lib/ 目录**，所以系统是从 APK 内部
（`extractNativeLibs=false` 的页面对齐方式）加载这整套库的。
一旦模块在磁盘上造出一个真实的 `nativeLibraryDir`（`/system/app/NQNfcNci/lib/arm64`），
nativeloader 就只认这个目录 → 其余 31 个库全部 `UnsatisfiedLinkError`
→ `com.android.nfc` 反复崩溃/重启。

**修法（v6.1）**：把 APK 里那 32 个库原样复制进影子 `lib/arm64/`，只替换其中的
`libsn100nfc-nci.so` 为补丁版。这样磁盘 lib 目录与 APK 内部 lib 目录等价，
加载行为不变。同时 `service.sh` 加了看门狗：开机 90 秒内若 NFC 进程重启 3 次，
自动写 `auto_reverted` 标记 → 下次重启自动不挂载、回原厂（最坏只是多重启一次）。

