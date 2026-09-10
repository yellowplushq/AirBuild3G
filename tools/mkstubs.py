#!/usr/bin/env python3
"""Generate .tbd text stubs from a legacy iPhoneOS SDK.

Xcode 27's linker refuses to link against the iOS 4.1 SDK's Mach-O dylibs:
they predate LC_VERSION_MIN_IPHONEOS, so ld reports them as built for an
'unknown' platform and errors out. It does, however, happily consume .tbd
text stubs that declare an armv7-ios target.

This walks the legacy SDK, reads each dylib's install name and exported
symbols, and writes a mirror tree of .tbd files that the linker accepts.
"""

import os
import plistlib
import subprocess
import sys

ARCH = "armv7"


def run(args):
    p = subprocess.run(args, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def install_name(binary):
    out = run(["otool", "-arch", ARCH, "-D", binary])
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    # otool -D prints "<path>:" then the install name
    return lines[-1] if len(lines) > 1 else None


def exported_symbols(binary):
    # -g external only, -U defined only; skip undefined/local symbols.
    out = run(["nm", "-arch", ARCH, "-gU", binary])
    syms = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[-1]
        kind = parts[-2]
        if kind in ("U", "u") or not name.startswith("_"):
            continue
        syms.add(name)
    return sorted(syms)


def is_macho_dylib(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce")


def write_tbd(dest, name, symbols):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        f.write("--- !tapi-tbd\n")
        f.write("tbd-version: 4\n")
        f.write("targets: [ %s-ios ]\n" % ARCH)
        f.write("install-name: '%s'\n" % name)
        f.write("current-version: 1\n")
        f.write("compatibility-version: 1\n")
        if symbols:
            f.write("exports:\n")
            f.write("  - targets: [ %s-ios ]\n" % ARCH)
            f.write("    symbols:\n")
            for s in symbols:
                f.write("      - '%s'\n" % s)
        f.write("...\n")


def candidates(sdk):
    """Yield every dylib/framework binary in the SDK worth stubbing."""
    roots = [
        "System/Library/Frameworks",
        "System/Library/PrivateFrameworks",
        "usr/lib",
    ]
    for rel_root in roots:
        root = os.path.join(sdk, rel_root)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            for fn in filenames:
                path = os.path.join(dirpath, fn)
                if os.path.islink(path):
                    continue
                if fn.endswith(".dylib") or is_macho_dylib(path):
                    yield path


def links(sdk):
    """Yield (symlink_path, target) pairs for .dylib aliases like libSystem.dylib."""
    for dirpath, dirnames, filenames in os.walk(os.path.join(sdk, "usr/lib")):
        for fn in filenames:
            path = os.path.join(dirpath, fn)
            if os.path.islink(path) and fn.endswith(".dylib"):
                yield path, os.readlink(path)


def main():
    if len(sys.argv) != 3:
        print("usage: mkstubs.py <legacy-sdk> <output-shim-dir>", file=sys.stderr)
        return 2
    sdk, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    if not os.path.isdir(sdk):
        print("no such SDK: %s" % sdk, file=sys.stderr)
        return 1

    count = 0
    for binary in candidates(sdk):
        name = install_name(binary)
        if not name:
            continue
        rel = os.path.relpath(binary, sdk)
        dest = os.path.join(out, rel)
        dest = dest[:-6] + ".tbd" if dest.endswith(".dylib") else dest + ".tbd"
        symbols = exported_symbols(binary)
        # libSystem re-exports dyld_stub_binder from libdyld, and ld needs it
        # for every lazy binding. It is missing from a libSystem that is itself
        # a stub -- the SDK recovered from a bootstrap payload by
        # tools/sdk_from_payload.py -- so name it here rather than fail the
        # link with "symbol dyld_stub_binder not found".
        if name == "/usr/lib/libSystem.B.dylib" and "dyld_stub_binder" not in symbols:
            symbols.append("dyld_stub_binder")
        write_tbd(dest, name, symbols)
        count += 1

    for link, target in links(sdk):
        rel = os.path.relpath(link, sdk)
        dest = os.path.join(out, rel[:-6] + ".tbd")
        target_tbd = target[:-6] + ".tbd" if target.endswith(".dylib") else target
        if os.path.lexists(dest):
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.symlink(target_tbd, dest)

    print("wrote %d stubs to %s" % (count, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
