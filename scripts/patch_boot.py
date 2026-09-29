#!/usr/bin/env python3
# OpenSesame boot 补丁器
# 用法: python patch_boot.py <原厂boot镜像> <输出boot镜像>
#
# 原理: 解出 boot 镜像里的内核 (LZ4 legacy 压缩), 把 same_magic()
# (vermagic 比对函数) 的入口两条指令 paciasp; stp x29,x30 改写为
#   mov w0, #1 ; ret
# 使 vermagic 校验恒通过, 然后重新压缩打包。
#
# 偏移与原始字节针对 vivo PD2339M / iQOO Neo9S Pro (MT6989)
# 内核 6.1.124-android14-11-maybe-dirty 校验过; 脚本会逐字节核对,
# 不匹配立即中止, 绝不盲改。
#
# 仅修改内核镜像里的 8 个字节, 文件其余部分 (含 96MB 分区尾部) 原样保留。

import struct
import sys

try:
    import lz4.block
except ImportError:
    sys.exit("需要先执行: pip install lz4")

MAGIC_LZ4_LEGACY = b"\x02\x21\x4c\x18"
LZ4_LEGACY_BLOCK = 8 * 1024 * 1024

# ---- 设备相关常量 (来自 _device/kernel_Image 的 kallsyms 分析) ----
KERNEL_VERSION_TAG = b"6.1.124-android14-11-maybe-dirty"
SAME_MAGIC_OFF = 0x18B2A4
# 函数入口原始指令: paciasp(BTI C); stp x29, x30, [sp, #-0x30]!
ORIG_BYTES = bytes.fromhex("3f2303d5fd7bbda9")
# 替换指令: mov w0, #1 ; ret
PATCH_BYTES = bytes.fromhex("200080 52c0035fd6".replace(" ", ""))


def extract_kernel(boot):
    if boot[:8] != b"ANDROID!":
        sys.exit("不是 ANDROID boot 镜像")
    hv = struct.unpack_from("<I", boot, 40)[0]
    if hv in (3, 4):
        ksize = struct.unpack_from("<I", boot, 8)[0]
        blob = boot[4096:4096 + ksize]
    else:
        psize = struct.unpack_from("<I", boot, 36)[0]
        ksize = struct.unpack_from("<I", boot, 8)[0]
        blob = boot[psize:psize + ksize]
    if blob[:2] == b"\x1f\x8b":
        import gzip
        return blob, gzip.decompress(blob)
    if blob[:4] == MAGIC_LZ4_LEGACY:
        return blob, decompress_lz4_legacy(blob)
    if blob[0x38:0x3C] == b"ARM\x64":
        return blob, blob
    sys.exit("未知内核压缩格式: " + blob[:8].hex())


def decompress_lz4_legacy(blob):
    out = bytearray()
    off = 4  # 跳过魔数
    while off + 4 <= len(blob):
        comp = struct.unpack_from("<I", blob, off)[0]
        off += 4
        if comp == 0 or off + comp > len(blob):
            break
        out += lz4.block.decompress(blob[off:off + comp],
                                    uncompressed_size=LZ4_LEGACY_BLOCK)
        off += comp
    return bytes(out)


def compress_lz4_legacy(img):
    out = bytearray(MAGIC_LZ4_LEGACY)
    for i in range(0, len(img), LZ4_LEGACY_BLOCK):
        blk = lz4.block.compress(img[i:i + LZ4_LEGACY_BLOCK], store_size=False)
        out += struct.pack("<I", len(blk)) + blk
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        sys.exit("用法: python patch_boot.py <原厂boot镜像> <输出文件>")
    src, dst = sys.argv[1], sys.argv[2]
    boot = bytearray(open(src, "rb").read())
    print("[*] boot 镜像: %d 字节" % len(boot))

    blob, img = extract_kernel(boot)
    print("[*] 内核 blob: %d 字节, 解压后: %d 字节" % (len(blob), len(img)))

    if KERNEL_VERSION_TAG not in img:
        sys.exit("! 内核版本不匹配 (找不到 %s), 这是别的设备的 boot, 拒绝打补丁" %
                 KERNEL_VERSION_TAG.decode())
    print("[*] 内核版本确认:", KERNEL_VERSION_TAG.decode())

    cur = img[SAME_MAGIC_OFF:SAME_MAGIC_OFF + len(ORIG_BYTES)]
    if cur != ORIG_BYTES:
        sys.exit("! 偏移 0x%x 处字节为 %s, 与预期 %s 不符, 拒绝盲改" %
                 (SAME_MAGIC_OFF, cur.hex(), ORIG_BYTES.hex()))
    print("[*] same_magic() 入口字节核对通过:", cur.hex())

    patched = bytearray(img)
    patched[SAME_MAGIC_OFF:SAME_MAGIC_OFF + len(PATCH_BYTES)] = PATCH_BYTES
    print("[*] 已改写 same_magic(): paciasp;stp -> mov w0,#1;ret (vermagic 恒通过)")

    new_blob = compress_lz4_legacy(bytes(patched))
    print("[*] 重压缩: %d -> %d 字节" % (len(blob), len(new_blob)))

    # 回写: 只替换头部字段与 kernel blob 区域, 文件总长与尾部保持原样
    hv = struct.unpack_from("<I", boot, 40)[0]
    koff = 4096 if hv in (3, 4) else struct.unpack_from("<I", boot, 36)[0]
    old_ksize = struct.unpack_from("<I", boot, 8)[0]
    if koff + len(new_blob) > len(boot):
        sys.exit("! 新内核 blob 超出镜像范围")
    out = bytearray(boot)
    struct.pack_into("<I", out, 8, len(new_blob))
    out[koff:koff + len(new_blob)] = new_blob
    # 旧 blob 比新 blob 长时, 多出的尾部清零 (kernel_size 已界定有效长度)
    if len(new_blob) < old_ksize:
        out[koff + len(new_blob):koff + old_ksize] = b"\x00" * (old_ksize - len(new_blob))
    open(dst, "wb").write(out)
    print("[*] 已写出:", dst, "(%d 字节)" % len(out))

    # ---- 回读验证 ----
    b2 = open(dst, "rb").read()
    _, img2 = extract_kernel(b2)
    if img2[SAME_MAGIC_OFF:SAME_MAGIC_OFF + len(PATCH_BYTES)] != PATCH_BYTES:
        sys.exit("! 回读验证失败")
    if img2[:SAME_MAGIC_OFF] != img[:SAME_MAGIC_OFF] or \
       img2[SAME_MAGIC_OFF + len(PATCH_BYTES):] != img[SAME_MAGIC_OFF + len(ORIG_BYTES):]:
        sys.exit("! 回读验证失败: 补丁区以外的内核字节发生了变化")
    print("[*] 回读验证通过: 内核镜像除 8 字节补丁外与原厂完全一致")


if __name__ == "__main__":
    main()
