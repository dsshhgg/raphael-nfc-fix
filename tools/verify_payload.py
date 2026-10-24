#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验仓库里随模块分发的载荷是否仍是「已知正确」的那几份。

它只做只读检查：大小 / sha256 / 关键偏移字节 / 关键配置项，不修改任何文件。
发布前跑一遍，可以避免把改坏的库打进 zip。

用法：
    python tools/verify_payload.py
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HAL = "modules/abort-fix-v3/system/vendor/lib64/nfc_nci.nqx.default.hw.so"
MFC1 = "modules/mfc-retx-fix-v6.1/payload/lib/arm64/libsn100nfc-nci.so"
MFC2 = "modules/mfc-retx-fix-v6.1/payload/lib/arm64_cap2/libsn100nfc-nci.so"
CONF = "modules/mifare-config-v5/system/vendor/etc/libnfc-nxp.conf"

# 期望值：见 docs/ 里的报告
EXPECT = {
    HAL: {"size": 254384,
          "sha256": "d8f77bb023d694310961a23bc53e3edc1ced9d7a679a67b8acacbe16a50ea350"},
    MFC1: {"size": 2034440,
           "sha256": "54cadcd30b1509eb918795e8c2bff23db8ad80e6b630fc62e048a6b8f575864e"},
    MFC2: {"size": 2034440,
           "sha256": "711a78daff1f5b90afe8296ad099d33299d4cdef0b29199cde13332d9087c0dc"},
    CONF: {"size": 15822,
           "sha256": "e495a5ef3df2c7111e2dab885205f8d7ad306c9dc6a4f7ba63d95464b7d293b2"},
}

# 打补丁后的关键字节（cmp 指令）
HAL_SITE = (0x1D910, "5f8d0171")            # cmp w10, #99
MFC_SITES = [(0x1975A0, 8), (0x199490, 8), (0x1A0214, 8), (0x1A7204, 8), (0x1A736C, 9)]


def cmp_bytes(reg, imm):
    import struct
    return struct.pack("<I", 0x71000000 | ((imm & 0xFFF) << 10) | ((reg & 0x1F) << 5) | 0x1F)


def check_common(rel):
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        return None, "文件不存在"
    data = open(path, "rb").read()
    digest = hashlib.sha256(data).hexdigest()
    exp = EXPECT[rel]
    problems = []
    if len(data) != exp["size"]:
        problems.append("大小 %d != %d" % (len(data), exp["size"]))
    if digest != exp["sha256"]:
        problems.append("sha256 %s != %s" % (digest[:16] + "…", exp["sha256"][:16] + "…"))
    return data, ("; ".join(problems) if problems else None)


def main():
    failures = 0

    def report(rel, extra=None):
        nonlocal failures
        data, err = check_common(rel)
        if data is None:
            print("!! %-62s %s" % (rel, err))
            failures += 1
            return None
        if err:
            print("!! %-62s %s" % (rel, err))
            failures += 1
        else:
            print("== %-62s size=%d sha256=%s" % (rel, len(data),
                                                  hashlib.sha256(data).hexdigest()[:16] + "…"))
        if extra:
            for msg, ok in extra(data):
                print("   %s %s" % ("ok  " if ok else "FAIL", msg))
                if not ok:
                    failures += 1
        return data

    def hal_extra(data):
        off, want = HAL_SITE
        got = data[off:off + 4].hex()
        yield ("0x%x = %s（期望 %s，cmp w10,#99）" % (off, got, want), got == want)

    def mfc_extra(imm):
        def inner(data):
            for off, reg in MFC_SITES:
                got = data[off:off + 4].hex()
                want = cmp_bytes(reg, imm).hex()
                yield ("0x%06x w%d = %s（期望 %s，cmp #%d）" % (off, reg, got, want, imm),
                       got == want)
        return inner

    def conf_extra(data):
        text = data.decode("utf-8", "replace").splitlines()
        hits = [l for l in text if l.startswith("MIFARE_READER_ENABLE=")]
        yield ("MIFARE_READER_ENABLE 唯一且为 0x00：%s" % (hits or "缺失"),
               hits == ["MIFARE_READER_ENABLE=0x00"])

    print("仓库根目录: %s\n" % ROOT)
    report(HAL, hal_extra)
    report(MFC1, mfc_extra(0))     # clamp1：最多试 1 次
    report(MFC2, mfc_extra(1))     # clamp2：允许 0..1，最多试 2 次
    report(CONF, conf_extra)

    print("")
    if failures:
        print("!! 有 %d 项不符，先别发布。" % failures)
        return 1
    print("== 全部载荷校验通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
