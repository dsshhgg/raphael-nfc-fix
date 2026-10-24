#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 HyperOS 4（MW15）`libsn100nfc-nci.so` 的 MIFARE Classic 重传钳制到 1 次（clamp1）
或 2 次（clamp2），等价于回到 HyperOS 2（MW10）的行为。

背景（详见 docs/root-cause-hyperos2-vs-hyperos4.md）：
    HOS2 的 libsn100nfc-nci.so 是 MW10.00.08（781,960 字节），认证失败一次就放弃；
    HOS4 换成 mw15_0B（2,034,440 字节），新增「MIFARE Classic 重传」循环：
    认证失败立刻重发 AUTH，最多 5 次。连发 AUTH 会把 PN553 的 I2C 从机拖死，
    HAL 写事务拿不到 ACK → 重试耗尽 → abort()。

    5 处结构相同的重传循环（读路径 / 写路径 / MiBeam 各一套）：

        0x197594  ldr  w8, [x23, #0x200]   ; 当前重传次数
        0x1975a0  cmp  w8, #4              ; ★ 上限 5 次（0..4）
        0x1975a4  b.hi "MFC maximum retransmission attempts reached"
        0x1975b0  add  w8, w8, #1
        0x1975bc  str  w8, [x23, #0x200]
        0x1975c8  bl   ...                 ; 重新下发 AUTH

改动（每处只改 1 个立即数字节；计数器从 0 开始，`cmp wN,#N` + `b.hi` 允许 0..N 共 N+1 次）：
    clamp1:  cmp wN, #4 -> cmp wN, #0   只允许 1 次，认证失败立刻放弃（与 MW10 一致，推荐）
    clamp2:  cmp wN, #4 -> cmp wN, #1   允许 2 次（clamp1 太激进时的退路）

用法：
    python tools/patch_mfc_retx.py <原厂 libsn100nfc-nci.so> --mode clamp1 [-o 输出]
    python tools/patch_mfc_retx.py <原厂 libsn100nfc-nci.so> --mode clamp2 [-o 输出]
    python tools/patch_mfc_retx.py --verify <已打补丁的 .so>

原厂库 sha256 13387c9ade4f01c9a0f5e0d4dc2337da30704eddd7d9b9631e245f2e329365f9
（取自 /system/app/NQNfcNci/NQNfcNci.apk 内的 lib/arm64-v8a，HyperOS 4.0.0.16）。
"""

import argparse
import hashlib
import struct
import sys

FILE_SIZE = 2034440
STOCK_SHA256 = "13387c9ade4f01c9a0f5e0d4dc2337da30704eddd7d9b9631e245f2e329365f9"
CLAMP1_SHA256 = "54cadcd30b1509eb918795e8c2bff23db8ad80e6b630fc62e048a6b8f575864e"
CLAMP2_SHA256 = "711a78daff1f5b90afe8296ad099d33299d4cdef0b29199cde13332d9087c0dc"

# (文件偏移, 寄存器号, 说明)  —— .text 段 VA 与文件偏移同为 0xa0000，故偏移即 VA
SITES = [
    (0x1975A0, 8, "写路径 / 数据缓冲 [x23+0xc0]"),
    (0x199490, 8, "读路径 / 数据缓冲 [x23+0xa0]"),
    (0x1A0214, 8, "读路径 / 数据缓冲 [x23+0x40]"),
    (0x1A7204, 8, "MiBeam 超时路径"),
    (0x1A736C, 9, "MiBeam 状态机"),
]

IMM = {"clamp1": 0, "clamp2": 1}   # 允许 0..IMM 共 IMM+1 次重传
MODE_SHA = {"clamp1": CLAMP1_SHA256, "clamp2": CLAMP2_SHA256}


def cmp_bytes(reg: int, imm: int) -> bytes:
    """AArch64 `cmp w<reg>, #<imm>` 的机器码（小端）。"""
    word = 0x71000000 | ((imm & 0xFFF) << 10) | ((reg & 0x1F) << 5) | 0x1F
    return struct.pack("<I", word)


# 自检：与反汇编里看到的一致
assert cmp_bytes(8, 4) == bytes.fromhex("1f110071")
assert cmp_bytes(8, 0) == bytes.fromhex("1f010071")
assert cmp_bytes(8, 1) == bytes.fromhex("1f050071")
assert cmp_bytes(9, 4) == bytes.fromhex("3f110071")
assert cmp_bytes(9, 0) == bytes.fromhex("3f010071")
assert cmp_bytes(9, 1) == bytes.fromhex("3f050071")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def detect_mode(data: bytes):
    """返回 (mode, 全部匹配) ；无法识别时 mode=None。"""
    stock = all(data[o:o + 4] == cmp_bytes(r, 4) for o, r, _ in SITES)
    if stock:
        return "stock", True
    for mode, imm in IMM.items():
        if all(data[o:o + 4] == cmp_bytes(r, imm) for o, r, _ in SITES):
            return mode, True
    return None, False


def do_verify(path: str) -> int:
    data = open(path, "rb").read()
    digest = sha256(data)
    print("文件   : %s" % path)
    print("大小   : %d 字节（原厂 %d）" % (len(data), FILE_SIZE))
    print("sha256 : %s" % digest)

    ok = len(data) == FILE_SIZE
    for off, reg, note in SITES:
        cur = data[off:off + 4].hex()
        tag = ""
        if data[off:off + 4] == cmp_bytes(reg, 4):
            tag = "原厂 cmp #4"
        elif data[off:off + 4] == cmp_bytes(reg, 0):
            tag = "clamp1 cmp #0"
        elif data[off:off + 4] == cmp_bytes(reg, 1):
            tag = "clamp2 cmp #1"
        else:
            tag = "!! 未知字节"
            ok = False
        print("  0x%06x w%d  %s  %s  (%s)" % (off, reg, cur, tag, note))

    mode, _ = detect_mode(data)
    if mode == "stock":
        print("== 这是原厂库，5 处重传上限都还是 5 次")
    elif mode in IMM:
        print("== 已钳制：%s（上限 %d 次）" % (mode, IMM[mode] + 1))
        if digest == MODE_SHA[mode]:
            print("   与随模块分发的载荷逐字节一致")
    else:
        print("!! 5 处字节不一致，这不是同一版库或已被别的方式改过")
        ok = False
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MIFARE Classic 重传钳制补丁（HyperOS 4 MW15）")
    ap.add_argument("source", help="输入的 libsn100nfc-nci.so")
    ap.add_argument("-o", "--output", help="输出路径（默认 <source>.<mode>.so）")
    ap.add_argument("--mode", choices=sorted(IMM), help="clamp1（只试 1 次）或 clamp2（最多 2 次）")
    ap.add_argument("--verify", action="store_true", help="只校验，不写文件")
    ap.add_argument("--force", action="store_true", help="跳过 sha256 校验（自担风险）")
    args = ap.parse_args(argv)

    if args.verify:
        return do_verify(args.source)
    if not args.mode:
        ap.error("写文件时必须给 --mode clamp1|clamp2（或用 --verify）")

    data = bytearray(open(args.source, "rb").read())

    if len(data) != FILE_SIZE:
        print("!! 文件大小 %d != 期望 %d" % (len(data), FILE_SIZE), file=sys.stderr)
        if not args.force:
            return 2

    digest = sha256(bytes(data))
    if digest != STOCK_SHA256 and not args.force:
        print("!! sha256 %s 不是已知的原厂库：%s" % (digest, STOCK_SHA256), file=sys.stderr)
        print("   这个库可能来自别的 HyperOS 小版本，布局未必相同。", file=sys.stderr)
        print("   确认无误可加 --force 重试（仍会逐点核对 cmp #4 字节）。", file=sys.stderr)
        return 2

    imm = IMM[args.mode]
    changed = 0
    for off, reg, note in SITES:
        stock = cmp_bytes(reg, 4)
        new = cmp_bytes(reg, imm)
        cur = bytes(data[off:off + 4])
        if cur == new:
            continue
        if cur != stock:
            print("!! 0x%06x 处是 %s，既不是原厂 %s 也不是目标 %s（%s）"
                  % (off, cur.hex(), stock.hex(), new.hex(), note), file=sys.stderr)
            print("   拒绝盲改，已中止（未写出任何文件）。", file=sys.stderr)
            return 3
        data[off:off + 4] = new
        changed += 1

    if changed == 0:
        print("== 输入已是 %s，无需重复打补丁" % args.mode)
        return 0

    out = args.output or ("%s.%s.so" % (args.source, args.mode))
    with open(out, "wb") as fh:
        fh.write(data)

    out_sha = sha256(bytes(data))
    print("已写出 : %s" % out)
    print("模式   : %s（上限 %d 次）" % (args.mode, imm + 1))
    print("改动   : %d 处 cmp #4 -> cmp #%d" % (changed, imm))
    print("大小   : %d 字节（未变）" % len(data))
    print("sha256 : %s" % out_sha)
    if out_sha == MODE_SHA[args.mode]:
        print("== 与 modules/mfc-retx-fix-v6.1/payload 里的载荷逐字节一致")
    else:
        print("!! 与随仓库分发的载荷哈希不同（输入不是同一份原厂库？）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
