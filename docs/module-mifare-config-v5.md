# NFC 加密卡防崩模块 v5.0

## 解决什么

HyperOS 4（`CP2A.260605.016` / `OS4.0.0.16.XPCCNXM`，raphael）上，贴加密 MIFARE 卡
（这类卡的 UID 形如 `04:14:DD:03`）时，`vendor.nxp.hardware.nfc@1.2-service`
会 SIGABRT 崩溃，tombstone 固定指向：

```
#00 pc libc.so (abort+160)
#01 pc 0x1db54 /vendor/lib64/nfc_nci.nqx.default.hw.so
        phNxpNciHal_write_unlocked(...)+1112
```

## 根因（实测确认）

NFC 栈对这类卡会反复下发 MIFARE AUTH 认证：

```
19:01  NxpNciX: 00000C 60 04 14 DD 03 21 D3 F7 D3 F7 D3 F7   (AUTH1A, 块 4)
       NxpNciR: 60 06 03 01 00 01                              (认证失败)
       …… 每 300 ms 重复一次
第 4 次之后：
       i2c_geni a84000.i2c: GSI QN err:0x0, status:0x4d3, err:2
       nq-nci 2-0028: nfc_write: failed to write after 3 retries
       NxpHal: write_unlocked failed - PN54X Maybe in Standby Mode (max count = 0x5)
       → 复位 → 上报 CORE_RESET_NTF → usleep(10000) → abort()
```

**芯片在连续几次 MIFARE 认证失败后会把 I2C 从机拉死**，之后所有写都是 `status = 0x1ff`。
软件层面没有可靠的复位手段（`unbind/bind nq-nci`、连 I2C 控制器一起重绑都救不回来），
只有整机重启能恢复。

A/B 实测：把 `MIFARE_READER_ENABLE` 关掉后，同一张卡连贴 4 分半、
`AUTH1A` 帧出现 **0 次**、`tombstone` **0 个**、HAL 进程全程存活。

## 这个模块做什么

只改一行：

```
/vendor/etc/libnfc-nxp.conf:30
- MIFARE_READER_ENABLE=0x01
+ MIFARE_READER_ENABLE=0x00
```

通过开机 overlay（KernelSU / Magisk 的 magic mount）+ 幂等 bind mount 兜底生效。
`/vendor` 分区本身**从不被改写**，卸载模块即恢复。

## 代价（务必先读）

关闭 MIFARE reader 之后：

- 加密 MIFARE 卡在 NFC Tools 里会从 `MifareClassic` 变成 `NfcA`，
  针对它的 MIFARE 认证会直接失败——**这类卡的读写用不了了**；
- NTAG / 普通 A 卡（Type-2）读写不受影响，`A2` 写页命令照常工作。

换句话说：**这是「不再崩」的开关，不是「加密卡也能写」的开关。**

## 安装

Magisk / KernelSU / APatch 刷入 `nfc_mifare_safe.zip`，重启。

安装时会校验 `/vendor/etc/libnfc-nxp.conf` 的大小与 `MIFARE_READER_ENABLE` 当前值，
不匹配就中止，不会刷坏。

## 验证

```
adb shell su -c "sh /data/adb/modules/nfc_mifare_safe/action.sh"
```

期望 `MIFARE 设置: MIFARE_READER_ENABLE=0x00`。

或者：

```
adb shell su -c "grep -m1 MIFARE_READER_ENABLE /vendor/etc/libnfc-nxp.conf"
adb shell su -c "cat /data/adb/nfc_mifare_safe/nfc_fix.log"
```

## 恢复原厂行为

```
adb shell su -c "touch /data/adb/nfc_mifare_safe/stock_mode"
```

然后重启。想再打开就 `rm` 掉该文件再重启。

## 校验值

```
原厂 /vendor/etc/libnfc-nxp.conf  md5 0673c57efe143fe1ad5e215dd09b3dc8  15823 字节
模块载荷                          md5 03a5c55af8ccdf87ceeb957fcb1d8acd  15822 字节
载荷 sha256                       e495a5ef3df2c7111e2dab885205f8d7ad306c9dc6a4f7ba63d95464b7d293b2
```
