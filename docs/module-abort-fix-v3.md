# NFC 写卡崩溃修复模块 v3.0

针对 Redmi K20 Pro（raphael）+ HyperOS 4.0.0.16（`CP2A.260605.016` / `OS4.0.0.16.XPCCNXM`）
+ `4.14.357-Zundamon-Evo-v20260827-1` 内核的 **NFC HAL abort() 崩溃**。

---

## 1. 崩溃是什么

tombstone（`/data/tombstones/tombstone_24` 等，signal 6 SIGABRT）：

```
#00 abort                                   libc.so
#01 phNxpNciHal_write_unlocked(...)+1112    nfc_nci.nqx.default.hw.so
#02 phNxpNciHal_write(...)+276
#03 Nfc::write(hidl_vec<uint8_t> const&)+132  vendor.nxp.hardware.nfc@1.2-service
#04 _hidl_write / #05 onTransact / #06 transact / ... joinThreadPool
```

调用者是 `com.android.nfc` 的 **写卡**路径。用户现象：**读卡正常，扫描加密卡 / 手环门禁卡（MIFARE Classic）时崩溃，之后 NFC 开关消失。**

## 2. 根因（反汇编确认，非猜测）

`phNxpNciHal_write_unlocked` 里的事务重试循环：

| 地址 | 指令 | 含义 |
|---|---|---|
| `0x1d8fc` | `ldrh w8,[sp,#0x30]` | 读本次事务状态 |
| `0x1d900` | `cbz w8, #0x1da30` | 成功 → 清标志返回 |
| `0x1d904` | `ldrh w10,[x23,#0x2fc]` | `w10 = retry_cnt` |
| `0x1d90c` | `add w8, w10, #1` | |
| **`0x1d910`** | **`cmp w10, #4`** | **重试上限 = 5 次** |
| `0x1d918` | `b.hi #0x1da3c` | 超限 → 放弃 |
| `0x1d8a8` | `mov w0,#10000; usleep` | 每次重试间隔 **10 ms** |
| `0x1d8b0` | `bl phTmlNfc_Write` | 重发 |
| `0x1da3c`→`0x1db54` | `bl abort` | 放弃后：日志 → `phTmlNfc_IoCtl(0x8001)` 复位传输层 → **abort()** |

**5 次 × 10 ms ≈ 50 ms 容忍窗口。** 扫描 MIFARE Classic（加密卡/手环卡）时，芯片要处理加密
握手，会短暂占住 GENI I2C 总线；`nq-nci` 驱动内部重试 3 次仍返回
`nfc_write: failed to write after 3 retries`（dmesg 里伴随 `i2c_geni ... GSI QN err:0x0, status:0x4d3, err:2`），
HAL 这 50 ms 等不到就自杀。

**为什么 HyperOS 2 不崩**：两 ROM 的 NFC 软件栈逐字节完全相同（HAL `.so` sha256、
HIDL service、`libsn100u_fw.so`、`libnfc-nxp.conf`、`dtbo.img` 全部一致），
差异在**内核**（HOS2 `4.14.357-Zundamon-v4.1` vs HOS4 `4.14.357-Zundamon-Evo-v20260827-1`）。
新内核下芯片占住总线的时间更长，原厂那 50 ms 就不够了。

## 3. 这个模块做什么

**只改一条指令**（4 字节里的 2 个字节）：

```
0x1d910  cmp w10, #4    (5f 11 00 71)   ← 原厂：最多 5 次
0x1d910  cmp w10, #99   (5f 8d 01 71)   ← 本模块：最多 100 次 ≈ 1 秒
```

- **abort 逻辑完全保留**。真失败（芯片彻底不响应）时仍会 abort → init 重启 HAL → 芯片重新上电，
  这是原厂的自愈机制，不破坏它。
- 改动仅 2 字节，`size`、`BuildId`（`9edb171e79cb93d44e64f3e7be460440`）与符号表全部不变。

> 上一版 v1.2 的做法是「把 `bl abort` 换成跳转」，实测**有害**：HAL 不再自杀，而是挂着等死芯片，
> `com.android.nfc` 启动超时 → 每 15 秒一次 ANR → NFC 开关直接消失。v3 已废弃该做法。

## 4. 安装

KernelSU / Magisk 管理器里「从本地安装」选 `nfc_abort_fix.zip`，**重启**。

- **Magisk**：走 magic mount，`system/vendor/lib64/...` 直接生效。
- **KernelSU（无需 metamodule）**：KernelSU 不挂载普通模块的 `system/`，但会执行模块的
  `post-mount.sh`（`userspace/ksud/src/init_event.rs:120`），本模块在那里做 mountless
  `mount -o bind` 把打过补丁的库覆盖到 `/vendor/lib64/nfc_nci.nqx.default.hw.so`。
- 若装了 metamodule（mountify / meta-overlayfs），`post-mount.sh` 检测到 overlay 已生效会自动跳过 bind。

安装时机校验：安装脚本会核对旧库的 BuildId，不匹配直接拒绝安装（防止刷到别的 ROM 上）。

## 5. 验证

```sh
# 1) 补丁是否在 /vendor 上生效
od -An -tx1 -j 121104 -N 4 /vendor/lib64/nfc_nci.nqx.default.hw.so
#   5f 8d 01 71 = 生效
#   5f 11 00 71 = 未生效（还是原厂）

# 2) 日志
cat /data/adb/modules/nfc_abort_fix/nfc_fix.log

# 3) 管理器里点模块「执行」也会打印同样信息（action.sh）
```

重启后建议先确认 NFC 开关存在、能读普通卡，再试加密卡 / 手环卡。

## 6. 回滚

```sh
# 立刻回到原厂库（重启生效）
touch /data/adb/modules/nfc_abort_fix/disable
# 或直接管理器卸载
```

## 7. 如果 v3 仍崩溃

说明 1 秒也不够，按顺序试（都在 `E:\k20\`）：

1. `sh /sdcard/nfc_writewatch.sh` 抓写卡瞬间 dmesg，看 `nfc_write: failed` 是否仍伴随
   `GSI QN err:0x0, status:0x4d3, err:2` —— 若 status 变化，说明是别的原因。
2. 关掉 MIFARE 专有读取路径的配置实验（`MIFARE_READER_ENABLE=0x00`）——`E:\k20\nfc_mifare_fix\` 半成品。
3. 换内核验证：刷 HOS2 的 `kernel/boot_zd.img`（`4.14.357-Zundamon-v4.1`），若 NFC 正常即坐实内核假设，
   再针对性找 `nq-nci` / `i2c-msm-geni` 的差异。
4. 降 I2C 总线频率或调 `NXP_I2C_FRAGMENTATION_ENABLED=0x01`（`/vendor/etc/libnfc-nxp.conf` L91-93 默认关闭）。

## 8. 文件清单

| 文件 | 作用 |
|---|---|
| `module.prop` | 模块元信息（v3.0 / versionCode 300） |
| `customize.sh` | 安装时校验旧库 BuildId + 设置权限/上下文 |
| `post-fs-data.sh` | 尽早校验载荷完整性 |
| `post-mount.sh` | KernelSU 无 metamodule 时的 mountless bind 兜底 |
| `service.sh` | 开机后二次确认补丁生效 + 必要时重启 NFC HAL |
| `action.sh` | 管理器点「执行」时的状态报告 |
| `uninstall.sh` | 卸载时解除 bind |
| `system/vendor/lib64/nfc_nci.nqx.default.hw.so` | 打过 retry 补丁的库（254384 B） |
| `META-INF/com/google/android/update-binary` | 刷机入口（Magisk/KernelSU 通用） |
