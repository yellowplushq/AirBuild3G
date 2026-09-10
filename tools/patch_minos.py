#!/usr/bin/env python3
"""Rewrite a Mach-O's LC_VERSION_MIN_IPHONEOS to an older deployment target.

Xcode 27's linker hard-refuses "building for iOS with 4.0 minimum deployment
target", so the app is linked at 5.0 and stamped back down to 4.0 here. Only
the load command's version fields change; the linker already emits the layout
iOS 4 needs (LC_UNIXTHREAD, LC_DYLD_INFO_ONLY, no chained fixups).
"""

import struct
import sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
LC_VERSION_MIN_IPHONEOS = 0x25


def encode(ver):
    """'4.0' -> 0x00040000 (xxxx.yy.zz packed as 16.8.8)."""
    parts = [int(p) for p in ver.split(".")]
    parts += [0] * (3 - len(parts))
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def patch_slice(buf, offset, minos, sdk):
    magic = struct.unpack_from(">I", buf, offset)[0]
    if magic in (MH_MAGIC, MH_MAGIC_64):
        end, wide = ">I", magic == MH_MAGIC_64
    else:
        magic = struct.unpack_from("<I", buf, offset)[0]
        if magic not in (MH_MAGIC, MH_MAGIC_64):
            return 0
        end, wide = "<I", magic == MH_MAGIC_64

    ncmds = struct.unpack_from(end, buf, offset + 16)[0]
    pos = offset + (32 if wide else 28)
    patched = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(end + "I", buf, pos)
        if cmd == LC_VERSION_MIN_IPHONEOS:
            struct.pack_into(end + "I", buf, pos + 8, minos, sdk)
            patched += 1
        pos += cmdsize
    return patched


def main():
    if len(sys.argv) != 4:
        print("usage: patch_minos.py <macho> <min-version> <sdk-version>", file=sys.stderr)
        return 2
    path, minos, sdk = sys.argv[1], encode(sys.argv[2]), encode(sys.argv[3])

    with open(path, "rb") as f:
        buf = bytearray(f.read())

    if struct.unpack_from(">I", buf, 0)[0] == FAT_MAGIC:
        nfat = struct.unpack_from(">I", buf, 4)[0]
        offsets = [struct.unpack_from(">I", buf, 8 + i * 20 + 8)[0] for i in range(nfat)]
    else:
        offsets = [0]

    patched = sum(patch_slice(buf, o, minos, sdk) for o in offsets)
    if not patched:
        print("no LC_VERSION_MIN_IPHONEOS found in %s" % path, file=sys.stderr)
        return 1

    with open(path, "wb") as f:
        f.write(buf)
    print("patched %d slice(s) of %s to iOS %s" % (patched, path, sys.argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
