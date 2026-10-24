#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 NXP SN100 NFC HAL 的写事务重试上限从 5 次提到 100 次。

背景（详见 docs/root-cause-hyperos2-vs-hyperos4.md）：
    phNxpNciHal_write_unlocked() 在写事务失败后重试，原厂上限 5 次、间隔 10 ms，
    合计约 50 ms。读写 MIFARE Classic（加密卡 / 手环卡）时 PN553 会短暂占住
    GENI I2C 总线，超过 50 ms 就走到 abort() —— 表现为写卡瞬间 SIGABRT，
    之后 NFC 开关直接消失。

改动（只有 1 个立即数字节）：
    偏移 0x1d910（121104）  cmp w10, #4   (5f 11 00 71)
                         →  cmp w10, #99 (5f 8d 01 71)   最多 100 次 ≈ 1 秒
    文件大小 / BuildId / 符号表 / 段布局全部不变；abort() 分支原样保留，
    芯片真的不响应时仍然由 init 重启 HAL（原厂自愈机制不被破坏）。

用法：
    python tools/patch_hal_retry.py <原厂 nfc_nci.nqx.default.hw.so> [-o 输出路径]
    python tools/patch_hal_retry.py --verify <已打补丁的 .so>

原厂库取自 HyperOS 4.0.0.16（CP2A.260605.016 / OS4.0.0.16.XPCCNXM）：
254384 字节，BuildId 9edb171e79cb93d44e64f3e7be460440。
其他版本布局不保证一致，脚本默认拒绝；确有把握时可加 --force。
"""

import argparse
import hashlib
import struct
import sys

FILE_SIZE = 254384
PATCH_OFFSET = 0x1D910
BUILD_ID_OFFSET = 664
BUILD_ID_LEN = 16
EXPECTED_BUILD_ID = "9edb171e79cb93d44e64f3e7be460440"


def cmp_bytes(reg: int, imm: int) -> bytes:
    """AArch64 `cmp w<reg>, #<imm>` 的机器码（小端）。"""
    word = 0x71000000 | ((imm & 0xFFF) << 10) | ((reg & 0x1F) << 5) | 0x1F
    return struct.pack("<I", word)


STOCK = cmp_bytes(10, 4)      # 5f 11 00 71
PATCHED = cmp_bytes(10, 99)   # 5f 8d 01 71
assert STOCK == bytes.fromhex("5f110071"), STOCK.hex()
assert PATCHED == bytes.fromhex("5f8d0171"), PATCHED.hex()

PATCHED_SHA256 = "d8f77bb023d694310961a23bc53e3edc1ced9d7a679a67b8acacbe16a50ea350"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_id(data: bytes) -> str:
    return data[BUILD_ID_OFFSET:BUILD_ID_OFFSET + BUILD_ID_LEN].hex()


def report(data: bytes) -> dict:
    return {
        "size": len(data),
        "build_id": build_id(data),
        "site": data[PATCH_OFFSET:PATCH_OFFSET + 4].hex(),
        "sha256": sha256(data),
    }


def do_verify(path: str) -> int:
    data = open(path, "rb").read()
    info = report(data)
    ok = True

    print("文件      : %s" % path)
    print("大小      : %d 字节（原厂 %d）" % (info["size"], FILE_SIZE))
    print("BuildId   : %s（原厂 %s）" % (info["build_id"], EXPECTED_BUILD_ID))
    print("0x1d910   : %s" % info["site"])
    print("sha256    : %s" % info["sha256"])

    if info["size"] != FILE_SIZE:
        print("!! 大小不符，这不是同一版 HAL"); ok = False
    if info["build_id"] != EXPECTED_BUILD_ID:
        print("!! BuildId 不符，这不是同一版 HAL"); ok = False

    site = bytes.fromhex(info["site"])
    if site == PATCHED:
        print("== 已是补丁版（cmp w10,#99，最多 100 次）")
        if info["sha256"] != PATCHED_SHA256:
            print("   （哈希与随模块分发的载荷不同，但补丁点正确）")
    elif site == STOCK:
        print("== 仍是原厂版（cmp w10,#4，最多 5 次）")
    else:
        print("!! 补丁点字节既不是原厂也不是本脚本产物"); ok = False

    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="NXP SN100 NFC HAL 写事务重试上限补丁")
    ap.add_argument("source", help="输入的 nfc_nci.nqx.default.hw.so")
    ap.add_argument("-o", "--output", help="输出路径（默认 <source>.patched.so）")
    ap.add_argument("--verify", action="store_true", help="只校验，不写文件")
    ap.add_argument("--force", action="store_true", help="跳过 BuildId 校验（自担风险）")
    args = ap.parse_args(argv)

    if args.verify:
        return do_verify(args.source)

    data = bytearray(open(args.source, "rb").read())

    if len(data) != FILE_SIZE:
        print("!! 文件大小 %d != 期望 %d" % (len(data), FILE_SIZE), file=sys.stderr)
        if not args.force:
            return 2
    bid = build_id(bytes(data))
    if bid != EXPECTED_BUILD_ID:
        print("!! BuildId %s != 期望 %s" % (bid, EXPECTED_BUILD_ID), file=sys.stderr)
        if not args.force:
            print("   这可能是别的 ROM / 别的 NXP HAL，布局未必相同。", file=sys.stderr)
            print("   确认无误可加 --force 重试。", file=sys.stderr)
            return 2

    current = bytes(data[PATCH_OFFSET:PATCH_OFFSET + 4])
    if current == PATCHED:
        print("== 输入已是补丁版，无需重复打补丁")
        return 0
    if current != STOCK:
        print("!! 偏移 0x%x 处是 %s，既不是原厂 %s 也不是补丁版 %s"
              % (PATCH_OFFSET, current.hex(), STOCK.hex(), PATCHED.hex()), file=sys.stderr)
        print("   说明这个库的重试循环布局和已知版本不同，拒绝盲改。", file=sys.stderr)
        return 3

    data[PATCH_OFFSET:PATCH_OFFSET + 4] = PATCHED
    out = args.output or (args.source + ".patched.so")
    with open(out, "wb") as fh:
        fh.write(data)

    digest = sha256(bytes(data))
    print("已写出 : %s" % out)
    print("大小   : %d 字节（未变）" % len(data))
    print("BuildId: %s（未变）" % build_id(bytes(data)))
    print("0x1d910: %s -> %s  (cmp w10,#4 -> cmp w10,#99)"
          % (STOCK.hex(), PATCHED.hex()))
    print("sha256 : %s" % digest)
    if digest == PATCHED_SHA256:
        print("== 与 modules/abort-fix-v3 里的载荷逐字节一致")
    else:
        print("!! 与随仓库分发的载荷哈希不同（输入不是同一份原厂库？）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
