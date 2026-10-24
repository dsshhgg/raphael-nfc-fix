# NFC 写卡修复模块 v6.1（MFC 重传钳制）

目标：让 HyperOS 4 上的 `com.android.nfc` 既不崩、又能正常写 MIFARE Classic 卡
（小米手环空白卡 `04:14:DD:03:21`）。

## 结论从哪来

澎湃2 与澎湃4 的 **vendor 侧 NFC 栈（HAL / vendor service / 芯片固件 / libnfc-nxp.conf）
四个文件逐字节相同**，差异全在 system 侧的框架库：

| | 澎湃2 | 澎湃4 |
|---|---|---|
| `libsn100nfc-nci.so` | 781,960 B（MW10.00.08） | 2,034,440 B（mw15_0B） |
| MFC 重传代码 | **没有** | **有**，上限 5 次 |
| 小米 `NfcTagExtns`（非标卡秒退） | 没有 | 有 |

HAL 的 `abort` 就是被 MW15 这段重传打死的：

```
0x197594  ldr  w8, [x23, #0x200]    ; 重传计数
0x1975a0  cmp  w8, #4               ; ★ 上限 5 次（0..4）
0x1975a4  b.hi "MFC maximum retransmission attempts reached"
0x1975b0  add  w8, w8, #1
0x1975bc  str  w8, [x23, #0x200]
→ 连发 AUTH → PN553 I2C 挂死 → write_unlocked 失败 → abort
```

补丁 = 把这 5 处 `cmp wN,#4` 改成 `cmp wN,#0`（**每处只改 1 个字节**），
行为回到 MW10：认证失败一次就放弃，MIFARE reader 可以一直开着，卡不会被判成非标卡。

## 补丁表（文件偏移 = VA，因为 .text 段 VA 与文件偏移同为 0xa0000）

| 偏移 | 原指令 | 原字节 | 改后（clamp1） | 改后（clamp2） |
|---|---|---|---|---|
| 0x1975a0 | `cmp w8,#4` | `1f 11 00 71` | `1f 01 00 71` | `1f 05 00 71` |
| 0x199490 | `cmp w8,#4` | `1f 11 00 71` | `1f 01 00 71` | `1f 05 00 71` |
| 0x1a0214 | `cmp w8,#4` | `1f 11 00 71` | `1f 01 00 71` | `1f 05 00 71` |
| 0x1a7204 | `cmp w8,#4` | `1f 11 00 71` | `1f 01 00 71` | `1f 05 00 71` |
| 0x1a736c | `cmp w9,#4` | `3f 11 00 71` | `3f 01 00 71` | `3f 05 00 71` |

- 原厂库 sha256 `13387c9ade4f01c9a0f5e0d4dc2337da30704eddd7d9b9631e245f2e329365f9`
- clamp1（只试 1 次）`54cadcd30b1509eb918795e8c2bff23db8ad80e6b630fc62e048a6b8f575864e`
- clamp2（最多 2 次）`711a78daff1f5b90afe8296ad099d33299d4cdef0b29199cde13332d9087c0dc`

## 怎么装进来的（影子目录）

`com.android.nfc` 的 `legacyNativeLibraryDir` 是 `/system/app/NQNfcNci/lib`，
而原厂该目录**不存在**（原厂是 APK 自带 lib/arm64-v8a 那套库，直接从 APK 里加载）。
所以本模块在 `/system/app/NQNfcNci` 上 bind 挂一个影子目录，里面放：

```
/data/adb/nfc_mfc_retx_fix/stage/
├── NQNfcNci.apk                          ← 安装时从原厂复制的同一个 APK（不重签）
└── lib/arm64/
    ├── libsn100nfc-nci.so                ← clamp1/clamp2 补丁版
    └── 其余 31 个库                       ← 与原厂 APK 内的 lib/arm64-v8a 逐字节相同
```

这样 nativeloader 从磁盘加载我们这份补丁库，APK 签名完全没动，vendor 分区也没动。

### v6.1 关键修正（v6.0 崩溃循环的原因）

v6.0 只往 `lib/arm64/` 放了一个 `libsn100nfc-nci.so`。问题是：
原厂 APK 自带**一整套 32 个运行库**（`libsn100nfc_nci_jni.so`、`libclang_rt.ubsan_standalone-*.so`、
`libbase.so`、`libc++.so`、`libbinder.so`、`libchrome.so`…）。一旦磁盘上出现真实的
`nativeLibraryDir`，nativeloader 就只认这个目录 → 其余库全部找不到 →
`UnsatisfiedLinkError` → `com.android.nfc` 反复崩溃/重启。

v6.1 把整套 32 个库全部铺进去，目录与 APK 内 `lib/arm64-v8a` 等价，问题消除。

## 开关键

| 操作 | 命令 |
|---|---|
| 回原厂（不挂载） | `touch /data/adb/nfc_mfc_retx_fix/stock_mode && reboot` |
| 恢复模块 | `rm -f /data/adb/nfc_mfc_retx_fix/stock_mode && reboot` |
| 用 clamp2（保守，最多试 2 次） | `touch /data/adb/nfc_mfc_retx_fix/use_cap2` 后**重装模块** |
| 解除看门狗锁定 | `rm -f /data/adb/nfc_mfc_retx_fix/auto_reverted && reboot` |

## 看门狗

`service.sh` 在开机后盯 90 秒：如果 `com.android.nfc` 在这段时间内换了 3 次 pid
（= 崩溃重启 3 次），就判定影子库方案失败，写 `auto_reverted` 标记，
把最近的 logcat/tombstone 摘要写进日志，**下次重启自动不挂载、回原厂**。
所以最坏情况是「多重启一次」，不会变砖。

日志：`/data/adb/nfc_mfc_retx_fix/nfc_fix.log`

## 与 v5 模块的关系

- v5 `nfc_mifare_safe`：把 `MIFARE_READER_ENABLE` 改成 `0x00`，**不崩但卡被秒退、写不了**。
- v6（本模块）：**不改任何 vendor 配置**（保持原厂 `MIFARE_READER_ENABLE=0x01`），只钳制重传。
  目标是「不崩 + 能写」。**装 v6 前请先卸载/停用 v5**，否则 v5 的 conf 覆盖还在，
  卡还是会被小米 `NfcTagExtns` 判成非标卡秒退。

## 验证要点（重启后）

1. `grep NQNfcNci /proc/$(pidof com.android.nfc)/maps` —— 应看到 `/system/app/NQNfcNci/lib/arm64/...`
2. `logcat | grep -i 'retransmission\|RwMfc'` —— 贴卡时不应再出现 `Mifare Classic retransmission attempt`
3. `/data/tombstones` 不再新增 NFC 记录
4. NFC Tools 写卡时抓包能看到 `A2` 写指令真的发出去

## 风险

- 影子挂载依赖 `nativeLibraryDir` 这套机制，不同 HOS4 小版本可能行为不同；看门狗兜底。
- clamp1 只试 1 次，真卡第一次没认到会直接放弃（写卡时再贴一次即可）；不习惯就换 clamp2。
- 装完第一次开机若 NFC 反复重启，**再重启一次**就自动回原厂（看门狗已写标记）。
