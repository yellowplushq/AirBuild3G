#!/usr/bin/env python3
"""Build the AirBuild bootstrap payload: the Debian packages and the SDK
headers that turn a bare jailbroken iPhone into something that can compile
iOS software.

Plain Objective-C, and only that. Logos (.x/.xm) is written in perl and no
perl exists for armv6/iOS 4, so neither perl nor Theos — whose reason to
exist is running Logos — is shipped. A .m file, gcc, ld and ldid is the
whole road to an app here.

Nothing here resolves dependencies, at build time or at install time. apt-get
cannot help us: the compiler packages (iphone-gcc, libgcc, csu, odcctools) are
present as *files* on apt.saurik.com but absent from its Packages index, so
`apt-get install iphone-gcc` fails on a repository that plainly has it. The
answer is to pin exact filenames, with hashes, in Packaging/payload.lock.

    fetch_payload.py                 download everything the lock names
    fetch_payload.py --refresh       re-resolve versions and rewrite the lock
    fetch_payload.py --manifest      write the install plan the app reads
    fetch_payload.py --from-device root@host
                                     add every package already on that phone

The lock is committed; build/payload/ is not.
"""

import argparse
import bz2
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOCK = os.path.join(ROOT, "Packaging", "payload.lock")
OUT = os.path.join(ROOT, "build", "payload")
# Everything ever downloaded, including the candidates --refresh tried and
# rejected. Kept, because re-resolving is expensive; never shipped.
CACHE = os.path.join(OUT, "cache")
# Exactly what goes on the phone, and nothing else — one tree per target.
def staged_dir(target):
    return os.path.join(OUT, target)


# Two payloads, because the two devices share almost no compiler. A 3G on
# iOS 4 is armv6 and gets Telesphoreo GCC 4.2; a 3GS/iPod on iOS 6 is armv7
# and gets CoolStar's clang, which declares firmware (>= 5.0) and would be
# dead weight on the 3G. Shipping one package meant every 3G downloaded and
# unpacked 38 MB it then marked "Skipped".
TARGETS = {
    # Only what this script decides: which packages to stage, and which
    # compiler the manifest's verify and smoke steps should call. Package
    # names and control files belong to the Makefile, which builds the debs.
    "ios4": {"groups": ("core", "tls", "build", "compiler"), "compiler": "gcc"},
    "ios6": {"groups": ("core", "tls", "build", "clang"), "compiler": "clang"},
}

# TLSFix is on no apt repository this script reads; its author publishes the
# deb on GitHub. A source that is a URL is pinned to exactly that file.
TLSFIX_DEB = "https://github.com/nfzerox/TLSFix/releases/download/1.1/com.skyglow.tlsfix_1.1.deb"

SAURIK_DEBS = "http://apt.saurik.com/debs/"
BIGBOSS = "http://apt.thebigboss.org/repofiles/cydia/"
BIGBOSS_INDEX = BIGBOSS + "dists/stable/main/binary-iphoneos-arm/Packages.bz2"

# The firmware the payload has to run on. The 3G is 4.2.1; anything that
# declares a higher minimum is either skipped or gated to the iOS 6 devices.
TARGET_FIRMWARE = "4.0"

# ---------------------------------------------------------------------------
# What goes in, in the order it is installed.
#
# `group` is the manifest step a package belongs to. Order inside a group is
# the order dpkg sees them, which matters: coreutils-bin before coreutils,
# csu and libgcc before the compiler that links against them.
# ---------------------------------------------------------------------------

WANTED = [
    # group        name                       source     optional   [version]
    # A fifth field pins one exact version; without it --refresh takes the
    # newest the target can run.
    # Both linkers declare "Depends: openssl, uuid" -- odcctools on iOS 4 and
    # cctools on iOS 6 -- and neither runs without libuuid.16.dylib. They are
    # in core because both targets need them, and core installs first.
    ("core", "openssl", "saurik", False),
    ("core", "uuid", "saurik", False),
    ("core", "ncurses", "saurik", False),
    ("core", "readline", "saurik", False),
    ("core", "coreutils-bin", "saurik", False),
    ("core", "coreutils", "saurik", False),
    ("core", "findutils", "saurik", False),
    ("core", "diffutils", "saurik", False),
    ("core", "gawk", "saurik", False),
    ("core", "sed", "saurik", False),
    ("core", "grep", "saurik", False),
    ("core", "gzip", "saurik", False),
    ("core", "bzip2", "saurik", False),
    ("core", "tar", "saurik", False),
    ("core", "patch", "saurik", False),
    ("core", "unzip", "saurik", True),
    ("core", "less", "saurik", True),
    ("core", "adv-cmds", "saurik", True),
    ("core", "file-cmds", "saurik", True),
    ("core", "basic-cmds", "saurik", True),
    ("core", "shell-cmds", "saurik", True),
    ("core", "system-cmds", "saurik", True),
    ("core", "network-cmds", "saurik", True),
    ("core", "darwintools", "saurik", True),
    ("core", "debianutils", "saurik", True),
    ("core", "bash", "saurik", True),

    # TLS 1.2 with AES-GCM/ChaCha20 for CFNetwork (OpenSSL 1.1.1 behind
    # SecureTransport). Every current API endpoint refuses what iOS 4 speaks
    # on its own; AirBuild dlopens the tweak itself, so no respring is needed.
    ("tls", "com.skyglow.tlsfix", TLSFIX_DEB, False),

    ("build", "make", "saurik", False),
    ("build", "git", "saurik", True),
    ("build", "rsync", "saurik", True),

    # The compiler. csu and libgcc first: iphone-gcc links against both.
    ("compiler", "csu", "saurik", False),
    ("compiler", "libgcc", "saurik", False),
    ("compiler", "odcctools", "saurik", False),
    ("compiler", "iphone-gcc", "saurik", False),
    # The signer is per target. 610 is what the reference 3G has been signing
    # with all along and stays pinned there. It asserts on any thin armv7
    # Mach-O (`_assert(arch != NULL)`), which is every binary the clang
    # target produces, so iOS 6 gets 1:1.2.1 -- an armv6 build declaring
    # iOS 2.0, despite what Cydia's listing suggests -- which signs both.
    ("compiler", "ldid", "saurik", False, "610-5"),

    # The faster path, and armv7-only: these declare firmware (>= 5.0), so the
    # manifest gates the whole step and a 3G skips it. llvm-clang is only a
    # metapackage; llvm-clang32 is the armv7 compiler an iOS 6 device wants
    # (llvm-clang64 needs iOS 9 and arm64, so it is not here).
    ("clang", "org.coolstar.ld64", "bigboss", True),
    ("clang", "org.coolstar.cctools", "bigboss", True),
    ("clang", "org.coolstar.llvm-clang32", "bigboss", True),
    ("clang", "org.coolstar.llvm-clang", "bigboss", True),
    ("clang", "ldid", "saurik", True, "1:1.2.1"),
]

# Pinned so a wiped phone can be rebuilt from the payload alone, but NOT
# shipped in either target: see TARGETS above. Reinstalling a working
# jailbreak's dpkg, apt7, openssh and pam with saurik's newest builds is the
# blind upgrade the skill warns against, and on a 4.2.1 device it replaces
# binaries that then reference symbols iOS 4 does not have. Extended from a
# real device by --from-device.
BASE_DEFAULT = [
    "base", "firmware-sbin", "profile.d", "dpkg", "berkeleydb", "apt7",
    "apt7-lib", "apt7-key", "uikittools", "pam", "pam-modules", "openssh",
    "openssl", "libssl", "curl", "wget", "gnupg", "gettext", "lzma",
]

# ---------------------------------------------------------------------------
# Debian version ordering, so 3.81-10 sorts after 3.81-9.
# ---------------------------------------------------------------------------

def _order(char):
    if char.isdigit():
        return 0
    if char.isalpha():
        return ord(char)
    if char == "~":
        return -1
    return ord(char) + 256


def _compare_part(left, right):
    i = j = 0
    while i < len(left) or j < len(right):
        first = second = 0
        while (i < len(left) and not left[i].isdigit()) or (j < len(right) and not right[j].isdigit()):
            a = _order(left[i]) if i < len(left) and not left[i].isdigit() else 0
            b = _order(right[j]) if j < len(right) and not right[j].isdigit() else 0
            if a != b:
                return -1 if a < b else 1
            if i < len(left) and not left[i].isdigit():
                i += 1
            if j < len(right) and not right[j].isdigit():
                j += 1
        while i < len(left) and left[i].isdigit():
            first = first * 10 + int(left[i])
            i += 1
        while j < len(right) and right[j].isdigit():
            second = second * 10 + int(right[j])
            j += 1
        if first != second:
            return -1 if first < second else 1
    return 0


def version_key(version):
    """A sort key with Debian's ordering, usable with sorted()."""
    import functools
    return functools.cmp_to_key(compare_versions)(version)


def compare_versions(left, right):
    def split(v):
        epoch, _, rest = v.partition(":")
        if not rest:
            epoch, rest = "0", v
        upstream, _, revision = rest.rpartition("-")
        if not upstream:
            upstream, revision = rest, ""
        return int(epoch or 0), upstream, revision

    a_epoch, a_up, a_rev = split(left)
    b_epoch, b_up, b_rev = split(right)
    if a_epoch != b_epoch:
        return -1 if a_epoch < b_epoch else 1
    result = _compare_part(a_up, b_up)
    if result:
        return result
    return _compare_part(a_rev, b_rev)


def firmware_minimum(depends):
    """The `firmware (>= X)` a package insists on, or None."""
    match = re.search(r"firmware\s*\(\s*>=\s*([0-9][0-9.]*)\s*\)", depends or "")
    return match.group(1) if match else None


def firmware_maximum(depends):
    match = re.search(r"firmware\s*\(\s*<<?\s*([0-9][0-9.]*)\s*\)", depends or "")
    return match.group(1) if match else None


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

def fetch(url, timeout=120):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def saurik_candidates():
    """Every iphoneos-arm deb in saurik's file archive, newest first per name.

    This is an Apache directory listing, not an index. It is deliberately the
    source of truth here, because the packages we most need are missing from
    the index that sits next to it.
    """
    page = fetch(SAURIK_DEBS).decode("utf-8", "replace")
    candidates = {}
    for filename in re.findall(r'href="([^"]+_iphoneos-arm\.deb)"', page):
        name, _, rest = filename.rpartition("_iphoneos-arm.deb")[0].partition("_")
        if not rest:
            continue
        candidates.setdefault(name, []).append((rest, SAURIK_DEBS + filename))
    for name in candidates:
        candidates[name].sort(key=lambda pair: version_key(pair[0]), reverse=True)
    return candidates


def bigboss_candidates():
    index = bz2.decompress(fetch(BIGBOSS_INDEX)).decode("utf-8", "replace")
    candidates = {}
    for stanza in index.split("\n\n"):
        fields = {}
        key = None
        for line in stanza.split("\n"):
            if line.startswith(" ") and key:
                continue
            if ":" in line:
                key, _, value = line.partition(":")
                fields[key.strip()] = value.strip()
        name = fields.get("Package")
        filename = fields.get("Filename")
        if not name or not filename:
            continue
        candidates.setdefault(name, []).append((fields.get("Version", "0"), BIGBOSS + filename, fields))
    for name in candidates:
        candidates[name].sort(key=lambda item: version_key(item[0]), reverse=True)
    return candidates


def deb_control(path):
    """The control fields of a .deb, without needing dpkg-deb."""
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"!<arch>\n"):
        return {}
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii", "replace").strip() or 0)
        body = data[offset + 60:offset + 60 + size]
        offset += 60 + size + (size % 2)
        if not name.startswith("control.tar"):
            continue
        with tempfile.NamedTemporaryFile(suffix=name) as temporary:
            temporary.write(body)
            temporary.flush()
            with tarfile.open(temporary.name) as archive:
                for member in archive.getnames():
                    if member.lstrip("./") == "control":
                        text = archive.extractfile(member).read().decode("utf-8", "replace")
                        fields = {}
                        for line in text.split("\n"):
                            if line and not line.startswith(" ") and ":" in line:
                                key, _, value = line.partition(":")
                                fields[key.strip()] = value.strip()
                        return fields
    return {}


# The 3G is armv6 and nothing else. A package built only for armv7 installs
# without complaint and then fails at exec time with a message that blames the
# wrong thing, so the architectures are read here, out of the Mach-O headers,
# rather than inferred from a version number or a Depends line.
ARM_SUBTYPES = {0: "arm", 5: "armv4t", 6: "armv6", 7: "armv5tej", 8: "xscale",
                9: "armv7", 10: "armv7f", 11: "armv7s", 12: "armv7k",
                14: "armv6m", 15: "armv7m", 16: "armv7em"}
CPU_ARM = 12
CPU_ARM64 = 0x0100000C

# What an armv6 iPhone 3G can actually execute. "arm" is CPU_SUBTYPE_ARM_ALL,
# which is what the Telesphoreo-era packages are built as and which runs
# everywhere; armv6 is a superset of armv5 and armv4t, so those run too.
# armv7 and arm64 do not, and that is the whole point of looking.
ARMV6_RUNNABLE = frozenset(["arm", "armv4t", "armv5tej", "xscale", "armv6"])


def macho_architectures(head):
    import struct
    if len(head) < 8:
        return set()
    magic = struct.unpack(">I", head[:4])[0]
    if magic == 0xCAFEBABE:                       # fat, headers are big-endian
        count = struct.unpack(">I", head[4:8])[0]
        found = set()
        for index in range(min(count, 16)):
            start = 8 + index * 20
            if start + 8 > len(head):
                break
            cpu, subtype = struct.unpack(">ii", head[start:start + 8])
            if cpu == CPU_ARM:
                found.add(ARM_SUBTYPES.get(subtype & 0xFF, "arm?"))
            elif cpu == CPU_ARM64:
                found.add("arm64")
        return found
    for endian in ("<", ">"):
        value = struct.unpack(endian + "I", head[:4])[0]
        if value in (0xFEEDFACE, 0xFEEDFACF):
            cpu, subtype = struct.unpack(endian + "ii", head[4:12])
            if cpu == CPU_ARM:
                return {ARM_SUBTYPES.get(subtype & 0xFF, "arm?")}
            if cpu == CPU_ARM64:
                return {"arm64"}
            return {"cpu%d" % cpu}
    return set()


def deb_architectures(path):
    """(every architecture in the package, whether a 3G can run all of it).

    Judged per binary, not on the union: a package whose tools are armv6 but
    whose one important binary is armv7 would otherwise look fine.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"!<arch>\n"):
        return set(), True
    offset = 8
    found = set()
    runnable = True
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii", "replace").strip() or 0)
        body = data[offset + 60:offset + 60 + size]
        offset += 60 + size + (size % 2)
        if not name.startswith("data.tar"):
            continue
        with tempfile.NamedTemporaryFile(suffix=name) as temporary:
            temporary.write(body)
            temporary.flush()
            try:
                archive = tarfile.open(temporary.name)
            except tarfile.ReadError:
                return set(), True                 # lzma, most likely — not judged here
            with archive:
                for member in archive:
                    if not member.isfile() or member.size < 8:
                        continue
                    handle = archive.extractfile(member)
                    if handle is None:
                        continue
                    architectures = macho_architectures(handle.read(4096))
                    if not architectures:
                        continue                   # a script, a manual page, data
                    found |= architectures
                    if not (architectures & ARMV6_RUNNABLE):
                        runnable = False
        break
    return found, runnable


# Set by --offline: the cache is then the only source, and a miss is an error
# with a name in it rather than a connection that hangs and then fails.
OFFLINE = False


def download(url, directory):
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, url.rsplit("/", 1)[-1])
    if not os.path.exists(path):
        if OFFLINE:
            raise SystemExit("offline: %s is not in %s"
                             % (os.path.basename(path), directory))
        sys.stderr.write("  fetching %s\n" % os.path.basename(path))
        data = fetch(url)
        with open(path, "wb") as handle:
            handle.write(data)
    return path


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# The lock
# ---------------------------------------------------------------------------

FIELDS = ["group", "name", "version", "optional", "minFirmware", "maxFirmware",
          "archs", "url", "sha256", "size"]


def read_lock():
    entries = []
    if not os.path.exists(LOCK):
        return entries
    with open(LOCK) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != len(FIELDS):
                raise SystemExit("payload.lock: expected %d fields, got %d in %r"
                                 % (len(FIELDS), len(parts), line))
            entries.append(dict(zip(FIELDS, parts)))
    return entries


def write_lock(entries):
    with open(LOCK, "w") as handle:
        handle.write("# AirBuild bootstrap payload — pinned, in install order.\n")
        handle.write("# Regenerate with: make payload-lock   (tools/fetch_payload.py --refresh)\n")
        handle.write("# %s\n" % "\t".join(FIELDS))
        for entry in entries:
            handle.write("\t".join(entry[field] for field in FIELDS) + "\n")


def refresh(from_device=None):
    sys.stderr.write("reading apt.saurik.com/debs/ …\n")
    saurik = saurik_candidates()
    sys.stderr.write("reading BigBoss index …\n")
    try:
        bigboss = bigboss_candidates()
    except Exception as error:                      # noqa: BLE001 - reported, not fatal
        sys.stderr.write("  BigBoss unavailable (%s); its packages are skipped\n" % error)
        bigboss = {}

    wanted = list(WANTED)
    base_names = list(BASE_DEFAULT)
    if from_device:
        base_names = device_packages(from_device) or base_names
    for name in base_names:
        if not any(entry[1] == name for entry in wanted):
            wanted.insert(0, ("base", name, "saurik", True))

    entries = []
    for group, name, source, optional, *pin in wanted:
        if source.startswith("http"):
            candidates = [("", source)]           # pinned file; version from its control
        else:
            pool = saurik if source == "saurik" else bigboss
            candidates = pool.get(name)
            if pin:
                candidates = [c for c in candidates or () if c[0] == pin[0]]
                # apt.saurik.com's listing omits some files it still serves
                # (ldid 1:1.2.1 redirects to cache.saurik.com); the name is
                # regular enough to spell out.
                if not candidates and source == "saurik":
                    candidates = [(pin[0], SAURIK_DEBS + "%s_%s_iphoneos-arm.deb"
                                   % (name, pin[0]))]
        if not candidates:
            sys.stderr.write("  %-28s not in %s\n" % (name, source))
            continue
        chosen = None
        # Newest first, but a package is only taken once its own control says
        # it will run on the firmware we are targeting. The alternative — trust
        # the version number — is how you end up shipping an arm64 ldid to a 3G.
        for candidate in candidates[:6]:
            version, url = candidate[0], candidate[1]
            try:
                path = download(url, CACHE)
            except Exception as error:              # noqa: BLE001
                sys.stderr.write("  %-28s %s: %s\n" % (name, version, error))
                continue
            control = deb_control(path)
            version = version or control.get("Version", "?")
            architecture = control.get("Architecture", "iphoneos-arm")
            if architecture not in ("iphoneos-arm", "darwin-arm", "all"):
                continue
            minimum = firmware_minimum(control.get("Depends", ""))
            maximum = firmware_maximum(control.get("Depends", ""))
            if minimum and compare_versions(minimum, TARGET_FIRMWARE) > 0 and group != "clang":
                sys.stderr.write("  %-28s %s needs iOS %s; trying older\n" % (name, version, minimum))
                continue
            architectures, runnable = deb_architectures(path)
            # armv6 or nothing on a 3G. The clang group is the armv7 path by
            # definition and is gated on firmware instead.
            if not runnable and group != "clang":
                sys.stderr.write("  %-28s %s is %s, which a 3G cannot run; trying older\n"
                                 % (name, version, "/".join(sorted(architectures))))
                continue
            chosen = (version, url, path, minimum, maximum, architectures)
            break
        if chosen is None:
            sys.stderr.write("  %-28s no usable version\n" % name)
            continue
        version, url, path, minimum, maximum, architectures = chosen
        entries.append({
            "group": group,
            "name": name,
            "version": version,
            "optional": "1" if optional else "0",
            "minFirmware": minimum or "",
            "maxFirmware": maximum or "",
            "archs": "/".join(sorted(architectures)) or "-",
            "url": url,
            "sha256": sha256_of(path),
            "size": str(os.path.getsize(path)),
        })
        sys.stderr.write("  %-28s %-18s %s\n" % (name, version, "/".join(sorted(architectures)) or "script"))

    order = {group: index for index, group in
             enumerate(["base", "core", "tls", "build", "compiler", "clang"])}
    entries.sort(key=lambda entry: order.get(entry["group"], 99))
    write_lock(entries)
    sys.stderr.write("wrote %s (%d packages)\n" % (os.path.relpath(LOCK, ROOT), len(entries)))


def device_packages(target):
    """Every package installed on a phone, so the payload can put it back.

    The phone has no sort, wc, head or awk, and its sh expands ${...} inside a
    dpkg-query format string — so the status file is copied here and parsed
    here, which is also the only way this works against a device whose dpkg is
    already broken.
    """
    sys.stderr.write("reading /var/lib/dpkg/status from %s …\n" % target)
    try:
        text = subprocess.check_output(
            ["ssh", "-o", "PreferredAuthentications=password,publickey",
             "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
             target, "cat /var/lib/dpkg/status"],
            timeout=120).decode("utf-8", "replace")
    except Exception as error:                      # noqa: BLE001
        sys.stderr.write("  cannot read the device (%s); using the built-in list\n" % error)
        return []
    names = []
    for stanza in text.split("\n\n"):
        fields = dict(
            (line.partition(":")[0].strip(), line.partition(":")[2].strip())
            for line in stanza.split("\n") if ":" in line and not line.startswith(" "))
        if fields.get("Status", "").endswith("installed") and fields.get("Package"):
            names.append(fields["Package"])
    sys.stderr.write("  %d packages installed on the device\n" % len(names))
    return names


# ---------------------------------------------------------------------------
# Download, verify, stage
# ---------------------------------------------------------------------------

def entries_for(entries, target):
    groups = TARGETS[target]["groups"]
    return [entry for entry in entries if entry["group"] in groups]


def stage(target):
    entries = entries_for(read_lock(), target)
    if not entries:
        raise SystemExit("payload.lock is empty — run --refresh first")
    staged = staged_dir(target)
    debs = os.path.join(staged, "debs")
    if os.path.isdir(debs):
        shutil.rmtree(debs)                        # a dropped pin must not linger
    os.makedirs(debs, exist_ok=True)
    total = 0
    for entry in entries:
        path = download(entry["url"], CACHE)
        digest = sha256_of(path)
        if digest != entry["sha256"]:
            raise SystemExit("%s: sha256 is %s, the lock says %s"
                             % (os.path.basename(path), digest, entry["sha256"]))
        shutil.copy2(path, os.path.join(debs, os.path.basename(path)))
        total += os.path.getsize(path)
    sys.stderr.write("%s: %d packages verified, %.1f MB staged in %s\n"
                     % (target, len(entries), total / 1e6,
                        os.path.relpath(staged, ROOT)))
    stage_sdk(staged, target)
    # The staged tree is copied verbatim into the deb, so what is in it is what
    # a phone gets. Anything an earlier build left behind and this one no
    # longer produces has to go — dropping Theos still shipped theos.tar.gz,
    # 0.76 MB of a build system the manifest no longer mentions.
    for name in sorted(os.listdir(staged)):
        if name not in ("debs", "manifest.plist", "sdk.tar.gz"):
            path = os.path.join(staged, name)
            sys.stderr.write("  dropping %s, nothing produces it any more\n" % name)
            shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
    return entries


def stage_sdk(staged, target):
    """An SDK the on-device compiler can actually use.

    Three things have to be true, and none of them is true of the SDK as it
    ships:

    * For GCC, the headers must not declare blocks. The 3G's compiler is Apple
      GCC 4.2 build 5555 (2008); blocks arrived in build 5646, and the 4.1
      headers declare them unguarded, so a plain `#import <UIKit/UIKit.h>`
      will not parse. tools/sanitize_sdk.py removes those declarations,
      leaving the iOS 3-era API surface — which iOS 4 runs perfectly well.
      The clang target keeps the headers as Apple wrote them: clang has
      blocks, and the sanitiser is worse than useless to it — it drops
      `typedef … (^NSComparator)` and `dispatch_block_t` but not the methods
      that take them, so Foundation itself stops parsing ("expected a type"
      in NSSortDescriptor.h, eighteen times over).
    * There must be something to link against. Since iOS 3.1 every system
      library lives in the dyld shared cache and
      /System/Library/Frameworks/Foundation.framework holds only an
      Info.plist. tools/mkdevstubs.py writes stubs that carry the real
      install names and the names of every symbol the real library exports,
      and no code at all; dyld binds them to the shared cache at launch.
      15 MB, against 163 MB for the SDK's own copies.
    * The whole thing has to stay small enough to ship.

    The result is about 35 MB of a 306 MB SDK.
    """
    compiler = TARGETS[target]["compiler"]
    source = os.path.expanduser(
        os.environ.get("LEGACY_SDK", "~/theos/sdks/iPhoneOS4.1.sdk"))
    if not os.path.isdir(source):
        sys.stderr.write("no SDK at %s; skipping\n" % source)
        return
    target = os.path.join(staged, "sdk.tar.gz")
    # Cached, but not past a change to what builds it: the tarball is the
    # output of these two scripts, and an edit to either has to reach the
    # phone. Skipping that check once shipped a payload whose stubs were a
    # release behind the flags in the manifest that linked against them.
    tools = [os.path.join(HERE, name)
             for name in ("sanitize_sdk.py", "mkdevstubs.py", "fetch_payload.py")]
    if os.path.exists(target) and all(
            os.path.getmtime(tool) <= os.path.getmtime(target) for tool in tools):
        return
    os.makedirs(staged, exist_ok=True)
    sys.stderr.write("packing SDK headers from %s …\n" % source)

    def keep(info):
        name = info.name
        if "/Headers/" in name or name.endswith("/Headers"):
            return info
        if "/usr/include" in name:
            return info
        if name.endswith(".modulemap") or name.endswith(".h") or name.endswith(".tbd"):
            return info
        if info.isdir():
            return info
        return None

    work = os.path.join(OUT, "sdkstage")
    sdk = os.path.join(work, "iPhoneOS4.1.sdk")
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(sdk)

    # Copy the headers out, then rewrite them in place: the SDK itself is the
    # host's and is never modified.
    with tarfile.open(os.path.join(work, "headers.tar"), "w") as archive:
        archive.add(source, arcname=".", filter=keep)
    with tarfile.open(os.path.join(work, "headers.tar")) as archive:
        archive.extractall(sdk, filter="tar")
    os.remove(os.path.join(work, "headers.tar"))

    # Same stubs either way in spirit, but built for the family that links
    # against them: an armv6 3G, or an armv7 3GS running clang.
    if compiler == "gcc":
        run_tool("sanitize_sdk.py", sdk)
        run_tool("mkdevstubs.py", source, sdk, "armv6")
    else:
        run_tool("mkdevstubs.py", source, sdk, "armv7")

    # Same inputs, same bytes: mtimes and ownership are normalised, the member
    # order is sorted, and gzip is told not to stamp the time it ran. Building
    # the payload twice has to produce the same package or "reproducible" means
    # nothing.
    with open(target, "wb") as raw, \
            gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed, \
            tarfile.open(fileobj=compressed, mode="w") as archive:
        archive.add(sdk, arcname="iPhoneOS4.1.sdk", filter=normalise,
                    recursive=False)
        for base, directories, names in os.walk(sdk):
            directories.sort()
            for name in sorted(directories) + sorted(names):
                path = os.path.join(base, name)
                if os.path.isdir(path) and not os.path.islink(path):
                    if name not in directories:
                        continue
                archive.add(path, arcname="iPhoneOS4.1.sdk" + path[len(sdk):],
                            filter=normalise, recursive=False)


def normalise(info):
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def run_tool(name, *arguments):
    subprocess.run([sys.executable, os.path.join(HERE, name)] + list(arguments),
                   check=True)


# ---------------------------------------------------------------------------
# The install plan the app reads
# ---------------------------------------------------------------------------

def plist_escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def plist(value, indent=1):
    pad = "\t" * indent
    if isinstance(value, dict):
        lines = ["<dict>"]
        for key in value:
            lines.append("%s\t<key>%s</key>" % (pad, plist_escape(key)))
            lines.append("%s\t%s" % (pad, plist(value[key], indent + 1)))
        lines.append("%s</dict>" % pad)
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "<array/>"
        lines = ["<array>"]
        for item in value:
            lines.append("%s\t%s" % (pad, plist(item, indent + 1)))
        lines.append("%s</array>" % pad)
        return "\n".join(lines)
    if isinstance(value, bool):
        return "<true/>" if value else "<false/>"
    if isinstance(value, int):
        return "<integer>%d</integer>" % value
    return "<string>%s</string>" % plist_escape(str(value))


def step(identifier, phase, title, detail, kind, **extra):
    entry = {"id": identifier, "phase": phase, "title": title,
             "detail": detail, "kind": kind}
    entry.update(extra)
    return entry


def build_manifest(entries, version, target):
    def files(group):
        return ["debs/" + entry["url"].rsplit("/", 1)[-1]
                for entry in entries if entry["group"] == group]

    def packages(group):
        """Name and version per file, so the app can tell what is already
        installed without shelling out to dpkg-deb once per package."""
        return [{"name": entry["name"], "version": entry["version"],
                 "file": "debs/" + entry["url"].rsplit("/", 1)[-1]}
                for entry in entries if entry["group"] == group]

    def gate(group):
        values = [entry["minFirmware"] for entry in entries
                  if entry["group"] == group and entry["minFirmware"]]
        return max(values, key=version_key) if values else ""

    root = "/var/airbuild"
    steps = []

    # -- 1. Stash: make room on / before anything writes to it.
    steps.append(step("space", "stash", "Check Free Space",
                      "Free space on / and /var", "space"))
    steps.append(step("root", "stash", "Create AirBuild Folder",
                      "Projects and the toolchain", "mkdir",
                      paths=[root, root + "/projects", root + "/toolchain",
                             root + "/toolchain/sdks"]))
    # 95 MB of compiler is about to be installed into /usr. /usr/libexec holds
    # 78 MB of it and nothing in the boot path reads it; /usr/lib/gcc holds
    # another 7 MB. Neither is touched if / already has the room.
    steps.append(step("stash-usr", "stash", "Make Room for the Compiler",
                      "Moves /usr/libexec to the data partition (78 MB)",
                      "stash", paths=["/usr/libexec"], skipIfFreeKB=143360))
    steps.append(step("stash-gcc", "stash", "Make Room for the Runtime",
                      "Moves /usr/lib/gcc to the data partition (7 MB)", "stash",
                      paths=["/usr/lib/gcc"], skipIfFreeKB=143360))

    # -- 2. Install.
    if files("base"):
        steps.append(step("base", "install", "Repair System Packages",
                          "Reinstalls the base packages already here",
                          "dpkg", files=files("base"), packages=packages("base"), optional=True))
    steps.append(step("core", "install", "Core Utilities",
                      "coreutils, tar, sed, grep and find",
                      "dpkg", files=files("core"), packages=packages("core")))
    if files("tls"):
        steps.append(step("tlsfix", "install", "TLSFix",
                          "TLS 1.2 for today's servers",
                          "dpkg", files=files("tls"), packages=packages("tls")))
    steps.append(step("build", "install", "Build Tools",
                      "make and git", "dpkg", files=files("build"), packages=packages("build")))
    if files("compiler"):
        steps.append(step("compiler", "install", "Compiler",
                          "GCC 4.2 for armv6 and ldid (95 MB)",
                          "dpkg", files=files("compiler"), packages=packages("compiler")))
    if files("compiler"):
        # Telesphoreo's iphone-gcc installs only the triple-prefixed names --
        # arm-apple-darwin9-gcc and friends -- and no plain gcc at all.
        # Essentially every hand-written Makefile calls gcc or cc, so without
        # these the toolchain is installed and still unusable, which is
        # exactly how it failed the first time on the reference 3G.
        #
        # ln -sf, and never over a real file: idempotent for Retry, and it
        # cannot clobber a compiler somebody else put there.
        steps.append(step("cc-links", "install", "Compiler Commands",
                          "Adds gcc, cc and g++", "shell",
                          command="cd /usr/bin || exit 1; "
                                  "for pair in gcc:arm-apple-darwin9-gcc "
                                  "cc:arm-apple-darwin9-gcc "
                                  "g++:arm-apple-darwin9-g++ "
                                  "c++:arm-apple-darwin9-g++ "
                                  "cpp:arm-apple-darwin9-cpp; do "
                                  "link=${pair%%:*}; target=${pair#*:}; "
                                  "[ -x \"$target\" ] || continue; "
                                  "if [ -e \"$link\" ] && [ ! -L \"$link\" ]; then "
                                  "echo \"$link exists and is not a symlink; left alone\"; "
                                  "continue; fi; "
                                  "ln -sf \"$target\" \"$link\"; done; "
                                  "ls -l gcc cc g++ c++ cpp 2>&1; "
                                  "gcc --version 2>&1 | head -1"))
    steps.append(step("sdk", "install", "SDK Headers",
                      "iPhoneOS 4.1", "tar",
                      files=["sdk.tar.gz"], dest=root + "/toolchain/sdks", optional=True))
    if files("clang"):
        steps.append(step("clang", "install", "Compiler",
                          "Clang for armv7 and ldid", "dpkg",
                          files=files("clang"), packages=packages("clang"),
                          optional=True, minFirmware=gate("clang") or "5.0"))
        # CoolStar's package installs clang and clang++ and nothing else, and
        # the project template -- like every Makefile ever written -- calls
        # gcc. Same rule as the GCC links: never over a real file.
        steps.append(step("cc-links", "install", "Compiler Commands",
                          "Adds gcc, cc and g++", "shell",
                          command="cd /usr/bin || exit 1; "
                                  "for pair in gcc:clang cc:clang "
                                  "g++:clang++ c++:clang++; do "
                                  "link=${pair%%:*}; target=${pair#*:}; "
                                  "[ -x \"$target\" ] || continue; "
                                  "if [ -e \"$link\" ] && [ ! -L \"$link\" ]; then "
                                  "echo \"$link exists and is not a symlink; left alone\"; "
                                  "continue; fi; "
                                  "ln -sf \"$target\" \"$link\"; done; "
                                  "ls -l gcc cc g++ c++ 2>&1; "
                                  "gcc --version 2>&1 | head -1",
                          optional=True, minFirmware=gate("clang") or "5.0"))
    # GCC 4.2's own headers (stdarg.h, stddef.h) live outside the SDK, and
    # -isysroot hides them: it prefixes the compiler's built-in include path
    # too, and the SDK has no copy there. CPATH puts them back. clang needs
    # none of this.
    compiler = TARGETS[target]["compiler"]
    builtin = ("CPATH=/usr/lib/gcc/arm-apple-darwin9/4.2.1/include\n"
               if compiler == "gcc" else "")
    exports = "PATH SDKROOT IOS_CFLAGS IOS_LDFLAGS" + \
        (" CPATH" if builtin else "")
    steps.append(step("profile", "install", "Shell Environment",
                      "Adds the tools to every shell", "shell",
                      command="mkdir -p /etc/profile.d && cat > /etc/profile.d/airbuild.sh <<'SH'\n"
                              "PATH=/usr/bin:/bin:/usr/sbin:/sbin:%s/toolchain/bin:$PATH\n"
                              "SDKROOT=%s/toolchain/sdks/iPhoneOS4.1.sdk\n"
                              % (root, root) +
                              builtin +
                              "IOS_CFLAGS=\"-isysroot $SDKROOT\"\n"
                              # The SDK's libraries are stubs: real symbol
                              # names, no code. An ordinary two-level link, so
                              # a missing -framework is a link error rather
                              # than a crash on the phone at launch.
                              # -lobjc and CoreFoundation are explicit
                              # because the driver adds neither when its input
                              # is a .o: objc_msgSend and
                              # ___CFConstantStringClassReference live there.
                              "IOS_LDFLAGS=\"-isysroot $SDKROOT "
                              "-F$SDKROOT/System/Library/Frameworks "
                              "-L$SDKROOT/usr/lib "
                              "-lobjc -framework CoreFoundation\"\n"
                              "export %s\n" % exports +
                              "SH\n"
                              "chmod 0644 /etc/profile.d/airbuild.sh && "
                              "cat /etc/profile.d/airbuild.sh"))
    # Cydia offers a newer ldid (1:1.2.1, for iOS 5 and armv7) and a newer
    # network-cmds, and taking either breaks this phone: without ldid nothing
    # can be signed, and an unsigned binary is SIGKILLed at launch. Every
    # version here is pinned for a reason — iphone-gcc most of all, where the
    # newer build bus-errors before main — so the pins are marked held, which
    # is the same flag Cydia's own "Ignore Upgrades" sets and is what keeps
    # them out of its upgrade count. Our own installs still go through: dpkg -i
    # runs with --force-all, and that includes --force-hold.
    #
    # Two dpkg invocations, not one per package: dpkg rereads and rewrites its
    # whole database every time it is run.
    held = sorted({entry["name"] for group in TARGETS[target]["groups"]
                   for entry in packages(group)})
    if held:
        steps.append(step("hold", "install", "Pin Versions",
                          "Stops Cydia offering upgrades that break the toolchain",
                          "shell",
                          command="dpkg --get-selections > /tmp/airbuild.sel || exit 1; "
                                  "for p in %s; do "
                                  "grep -q \"^$p[[:space:]]\" /tmp/airbuild.sel && "
                                  "echo \"$p hold\"; done | dpkg --set-selections; "
                                  "rm -f /tmp/airbuild.sel; "
                                  "echo \"$(dpkg --get-selections | grep -c hold) packages pinned\""
                                  % " ".join(held)))

    # -- 3. Ready.
    steps.append(step("verify", "ready", "Check Toolchain",
                      "Runs each tool once", "shell",
                      command=". /etc/profile.d/airbuild.sh; "
                              "%s --version 2>&1 | head -1; make -v 2>&1 | head -1; "
                              % compiler +
                              "ld -v 2>&1 | head -1; ldid 2>&1 | head -1; "
                              "echo SDKROOT=$SDKROOT; ls $SDKROOT 2>&1 | head -3; "
                              "df -k / /private/var"))
    # No @autoreleasepool and no dot-m literals: this compiler is GCC 4.2.
    # No -arch either — Telesphoreo gcc emits armv6 already, and its driver
    # does not take Apple's flag. A Foundation-only binary from this toolchain
    # is SIGKILLed at launch on a 3G, which is why the test links UIKit.
    # The binary exits 7 on purpose, so `set -e` is exactly wrong here.
    smoke = (
        "#import <UIKit/UIKit.h>\\n"
        "int main(void) {\\n"
        "\\tNSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];\\n"
        "\\t[pool release];\\n"
        "\\treturn 7;\\n"
        "}\\n")
    steps.append(step("smoke", "ready", "Build Test App",
                      "Compiles, signs and runs a small app", "shell",
                      command=". /etc/profile.d/airbuild.sh; cd /tmp || exit 1; "
                              # %b, not %s: %s would write the backslash-n
                              # sequences literally into the source file.
                              "printf '%%b' '%s' > ablsmoke.m; "
                              # Compiling and linking are separate because they
                              # need different flags: the headers come from the
                              # SDK, the symbols from dyld.
                              "%s -c $IOS_CFLAGS ablsmoke.m -o ablsmoke.o "
                              "|| { echo 'Unable to compile the test app'; exit 1; }; "
                              "%s ablsmoke.o -o ablsmoke $IOS_LDFLAGS "
                              "-framework UIKit -framework Foundation "
                              "-framework CoreGraphics "
                              "|| { echo 'Unable to link the test app'; exit 1; }; "
                              "ldid -S ablsmoke || { echo 'Unable to sign the test app'; exit 1; }; "
                              "./ablsmoke; status=$?; rm -f ablsmoke ablsmoke.o ablsmoke.m; "
                              "if [ $status -eq 7 ]; then echo 'Compiled, signed and ran'; "
                              "else echo \"The test app was built but did not run correctly\"; exit 1; fi"
                              % (smoke, compiler, compiler)))

    return {"format_version": 1, "payload_version": version, "steps": steps}


def write_manifest(entries, version, destination, target):
    os.makedirs(destination, exist_ok=True)
    document = build_manifest(entries, version, target)
    path = os.path.join(destination, "manifest.plist")
    with open(path, "w") as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        handle.write('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                     '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n')
        handle.write('<plist version="1.0">\n')
        handle.write(plist(document, 0) + "\n")
        handle.write("</plist>\n")
    sys.stderr.write("wrote %s (%d steps)\n"
                     % (os.path.relpath(path, ROOT), len(document["steps"])))
    return path


def payload_version(entries):
    """A digest of the lock, so the app's "already installed" stamp changes
    whenever any pinned package does."""
    digest = hashlib.sha256()
    for entry in entries:
        digest.update((entry["name"] + entry["version"] + entry["sha256"]).encode())
    return digest.hexdigest()[:12]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--refresh", action="store_true",
                        help="re-resolve versions from both repositories and rewrite the lock")
    parser.add_argument("--from-device", metavar="USER@HOST",
                        help="also pin every package already installed on that phone")
    parser.add_argument("--manifest", metavar="DIR",
                        help="write manifest.plist into DIR (implies verifying the lock)")
    parser.add_argument("--manifest-only", action="store_true",
                        help="write the manifest without downloading anything")
    parser.add_argument("--target", choices=sorted(TARGETS), default="ios4",
                        help="which device family to build the payload for")
    parser.add_argument("--offline", action="store_true",
                        help="build only from build/payload/cache; never reach the network")
    arguments = parser.parse_args()

    global OFFLINE
    OFFLINE = arguments.offline
    if OFFLINE and (arguments.refresh or arguments.from_device):
        raise SystemExit("--offline cannot refresh the lock")

    if arguments.refresh or (arguments.from_device and not arguments.manifest):
        refresh(arguments.from_device)
        return

    target = arguments.target
    if arguments.manifest_only:
        entries = entries_for(read_lock(), target)
    else:
        entries = stage(target)
    # The version digest covers only this target's pins, so installing the
    # iOS 6 payload on top of the iOS 4 one re-runs the environment rather
    # than reading a stale "already installed" stamp.
    write_manifest(entries, payload_version(entries),
                   arguments.manifest or staged_dir(target), target)


if __name__ == "__main__":
    main()
