#!/usr/bin/env python3
"""Rewrite the cpusubtype of a thin Mach-O file.

Xcode 27's linker flatly refuses "-arch armv6". The armv6 slice is therefore
compiled as real armv6 code, relabelled as armv7 so the linker will accept it,
linked, and relabelled back to armv6 here. This is safe because the only code
ld itself contributes is the symbol stubs, and for a non-PIE arm target those
are plain ARM ldr/add instructions that predate armv7.
"""

import struct
import sys

MH_MAGIC = 0xFEEDFACE
SUBTYPES = {"armv6": 6, "armv7": 9}


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in SUBTYPES:
        print("usage: relabel_arch.py <thin-macho> <%s>" % "|".join(SUBTYPES),
              file=sys.stderr)
        return 2
    path, want = sys.argv[1], SUBTYPES[sys.argv[2]]

    with open(path, "rb") as f:
        buf = bytearray(f.read())

    if struct.unpack_from("<I", buf, 0)[0] != MH_MAGIC:
        print("%s is not a thin 32-bit little-endian Mach-O" % path, file=sys.stderr)
        return 1

    struct.pack_into("<i", buf, 8, want)
    with open(path, "wb") as f:
        f.write(buf)
    return 0


if __name__ == "__main__":
    sys.exit(main())
