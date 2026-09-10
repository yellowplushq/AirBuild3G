#!/usr/bin/env python3
"""Recover a buildable iPhoneOS4.1.sdk from a bootstrap payload package.

The real SDK is what `make` wants at LEGACY_SDK, and it is not always to
hand: Apple stopped serving Xcode 3.2.4, and no public mirror carries a 4.x
SDK. What every phone gets, though, is `sdk.tar.gz` inside
com.apple.airbuild.oss.bootstrap4 -- the headers as tools/sanitize_sdk.py left
them and the link stubs tools/mkdevstubs.py built -- and that is enough to
build the app and both payloads again, with three repairs:

* The headers went through the sanitiser, and an older sanitiser dropped
  `typedef … (^NSComparator)` and `dispatch_block_t` without dropping their
  users. The host clang has blocks, so the two typedefs go back where Apple
  had them; the sanitiser removes them again for the GCC payload, users and
  all this time.
* The stubs are thin armv6, and tools/mkstubs.py reads the armv7 slice.
  They are relabelled (cpusubtype only; there is no code in them).
* libSystem's stub does not carry dyld_stub_binder; tools/mkstubs.py adds it.

What comes out is the sanitised API surface, not Apple's: anything the
sanitiser removed is not there to compile against on the host either.

    usage: sdk_from_payload.py <bootstrap4.deb> <destination-dir>

writes <destination-dir>/iPhoneOS4.1.sdk, ready for `make LEGACY_SDK=...`.
"""

import os
import struct
import subprocess
import sys
import tarfile
import tempfile

SDK_MEMBER = "./var/airbuild/bootstrap/sdk.tar.gz"
NAME = "iPhoneOS4.1.sdk"
TYPEDEFS = (
	("System/Library/Frameworks/Foundation.framework/Headers/NSObjCRuntime.h",
	 "typedef NSInteger NSComparisonResult;\n",
	 "\n#if NS_BLOCKS_AVAILABLE\n"
	 "typedef NSComparisonResult (^NSComparator)(id obj1, id obj2);\n"
	 "#endif\n"),
	("usr/include/dispatch/base.h",
	 "typedef void (*dispatch_function_t)(void *);\n",
	 "\n#ifdef __BLOCKS__\ntypedef void (^dispatch_block_t)(void);\n#endif\n"),
)
MH_MAGIC = 0xFEEDFACE
CPU_TYPE_ARM, ARMV6, ARMV7 = 12, 6, 9


def ar_members(path):
	"""(name, bytes) for each member of a Debian package's ar archive."""
	with open(path, "rb") as handle:
		data = handle.read()
	if not data.startswith(b"!<arch>\n"):
		raise SystemExit("%s is not a .deb" % path)
	offset = 8
	while offset + 60 <= len(data):
		header = data[offset:offset + 60]
		name = header[0:16].decode("ascii", "replace").strip()
		size = int(header[48:58].decode("ascii", "replace").strip() or 0)
		yield name, data[offset + 60:offset + 60 + size]
		offset += 60 + size + (size % 2)


def extract_sdk(deb, destination):
	for name, body in ar_members(deb):
		if not name.startswith("data.tar"):
			continue
		with tempfile.NamedTemporaryFile(suffix=name) as temporary:
			temporary.write(body)
			temporary.flush()
			with tarfile.open(temporary.name) as archive:
				try:
					member = archive.getmember(SDK_MEMBER)
				except KeyError:
					raise SystemExit("%s has no %s" % (deb, SDK_MEMBER))
				inner = archive.extractfile(member)
				with tarfile.open(fileobj=inner, mode="r:gz") as sdk:
					sdk.extractall(destination, filter="tar")
		return os.path.join(destination, NAME)
	raise SystemExit("%s has no data.tar member" % deb)


def restore_typedefs(sdk):
	for relative, anchor, addition in TYPEDEFS:
		path = os.path.join(sdk, relative)
		with open(path, "r", errors="surrogateescape") as handle:
			text = handle.read()
		if addition.strip() in text:
			continue
		if text.count(anchor) != 1:
			raise SystemExit("%s: expected exactly one %r" % (path, anchor.strip()))
		with open(path, "w", errors="surrogateescape") as handle:
			handle.write(text.replace(anchor, anchor + addition))


def relabel_stubs(sdk):
	"""Every thin armv6 Mach-O that is not a startup object becomes armv7."""
	count = 0
	for base, _, names in os.walk(sdk):
		for name in names:
			path = os.path.join(base, name)
			if os.path.islink(path) or not os.path.isfile(path) or name.endswith(".o"):
				continue
			with open(path, "rb") as handle:
				head = handle.read(12)
			if len(head) < 12 or struct.unpack_from("<I", head, 0)[0] != MH_MAGIC:
				continue
			cpu, subtype = struct.unpack_from("<ii", head, 4)
			if cpu != CPU_TYPE_ARM or subtype != ARMV6:
				continue
			with open(path, "r+b") as handle:
				handle.seek(8)
				handle.write(struct.pack("<i", ARMV7))
			count += 1
	return count


def main():
	if len(sys.argv) != 3:
		raise SystemExit("usage: sdk_from_payload.py <bootstrap4.deb> <destination-dir>")
	deb, destination = sys.argv[1], sys.argv[2]
	if os.path.exists(os.path.join(destination, NAME)):
		raise SystemExit("%s already exists; remove it first" % os.path.join(destination, NAME))
	os.makedirs(destination, exist_ok=True)
	sdk = extract_sdk(deb, destination)
	restore_typedefs(sdk)
	stubs = relabel_stubs(sdk)
	print("wrote %s: headers with NSComparator and dispatch_block_t back, %d stubs relabelled armv7"
	      % (sdk, stubs))
	print("build with: make LEGACY_SDK=%s" % sdk)


if __name__ == "__main__":
	main()
