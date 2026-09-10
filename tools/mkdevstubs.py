#!/usr/bin/env python3
"""Build link-time stubs of the system libraries, for the on-device linker.

The phone has nothing to link against: since iOS 3.1 every system library lives
in the dyld shared cache, and /System/Library/Frameworks/Foundation.framework
holds an Info.plist and nothing else. The SDK's own copies would work, but they
are the real binaries and UIKit alone is 47 MB.

So each stub carries the original install name and the *names* of every symbol
the real library exports, and nothing else: no code, no data, every symbol
aliased to the same empty byte. That is enough for the linker to resolve a
reference and record which library it came from, and dyld then binds it to the
real library in the shared cache at launch. UIKit costs 250 KB this way.

The names matter. An earlier version shipped stubs with no symbols at all and
linked with -undefined dynamic_lookup, which is 3.8 MB rather than 15 MB but
turns a forgotten `-framework UIKit` from a link error into a launch crash:
nothing resolves against the stub, so no LC_LOAD_DYLIB is recorded, the link
succeeds, and dyld dies with "Symbol not found: _OBJC_CLASS_$_NSAutoreleasePool,
Expected in: dynamic lookup". Undefined symbols are supposed to be a link error.

Same armv6 problem as the app, same answer: ld refuses -arch armv6, so the
object is compiled armv6, relabelled armv7 for the link, and relabelled back
(tools/relabel_arch.py), then stamped to a 4.0 target (tools/patch_minos.py).
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHIM = os.path.join(ROOT, "build/sdkshim/usr/lib")
# ld will not link a dylib against itself, so libSystem is built under another
# name and renamed afterwards.
SELF = "/usr/lib/libSystem.B.dylib"
PLACEHOLDER = "/usr/lib/libSystem.airbuild-stub.dylib"
# A symbol name the assembler will take unquoted. Everything the SDK exports
# looks like this; anything that does not is skipped rather than escaped.
SYMBOL = re.compile(r"^[A-Za-z_.$][A-Za-z0-9_.$]*$")
# nm's type letters for a symbol that lives in __TEXT. Everything else defined
# is data as far as a stub is concerned.
TEXT_KINDS = frozenset("Tti")
# $ld$add$os3.0$_OBJC_CLASS_$_NSURL and friends are directives to the linker,
# not symbols anything can reference. Re-exporting them from a stub only makes
# the on-device ld print "bad symbol version" for each one.
DIRECTIVE_PREFIX = "$ld$"


def run(*command):
	return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def install_name(binary):
	for line in run("otool", "-D", binary).splitlines():
		line = line.strip()
		if line and not line.endswith(":"):
			return line
	return None


def exported_symbols(binary):
	"""The library's defined global symbols, split into text and data.

	nm prints `<address> <kind> <name>`, dropping the address for a symbol
	that has none, so the address column is recognised by being wider than the
	single letter that follows it.
	"""
	text, data = [], []
	for line in run("nm", "-gU", binary).splitlines():
		fields = line.split()
		if fields and len(fields[0]) > 1:
			fields = fields[1:]
		if len(fields) < 2 or not SYMBOL.match(fields[1]) or \
				fields[1].startswith(DIRECTIVE_PREFIX):
			continue
		(text if fields[0] in TEXT_KINDS else data).append(fields[1])
	return text, data


def stub_assembly(text, data):
	lines = [".section __TEXT,__text", ".align 2", "_airbuild_stub_text:", ".short 0"]
	lines += [line for name in text
		for line in (".globl %s" % name, ".set %s, _airbuild_stub_text" % name)]
	lines += [".section __DATA,__data", ".align 2", "_airbuild_stub_data:", ".long 0"]
	lines += [line for name in data
		for line in (".globl %s" % name, ".set %s, _airbuild_stub_data" % name)]
	return "\n".join(lines) + "\n"


class Builder(object):
	def __init__(self, sdk, arch, workdir):
		self.sdk, self.arch = sdk, arch
		self.clang = run("xcrun", "-f", "clang").strip()
		self.work = workdir
		# ld refuses -arch armv6, so armv6 is built as armv7 and relabelled.
		self.link_arch = "armv7" if arch == "armv6" else arch
		self.symbols = 0

	def build(self, source, output):
		name = install_name(source)
		if not name:
			return False
		text, data = exported_symbols(source)
		self.symbols += len(text) + len(data)
		assembly = os.path.join(self.work, "stub.s")
		obj = os.path.join(self.work, "stub.o")
		with open(assembly, "w") as handle:
			handle.write(stub_assembly(text, data))
		subprocess.run([self.clang, "-arch", self.link_arch, "-isysroot", self.sdk,
			"-c", assembly, "-o", obj], check=True, capture_output=True)
		os.makedirs(os.path.dirname(output), exist_ok=True)
		# -no_uuid keeps the output a function of its input, so two runs of
		# `make payload` produce the same bytes.
		subprocess.run([self.clang, "-arch", self.link_arch, "-isysroot", self.sdk,
			"-dynamiclib", "-mios-version-min=5.0", "-L", SHIM,
			"-Wl,-no_pie", "-Wl,-no_uuid",
			"-install_name", PLACEHOLDER if name == SELF else name,
			obj, "-o", output], check=True, capture_output=True)
		if name == SELF:
			run("install_name_tool", "-id", name, output)
		if self.arch != self.link_arch:
			run("python3", os.path.join(HERE, "relabel_arch.py"), output, self.arch)
		run("python3", os.path.join(HERE, "patch_minos.py"), output, "4.0", "4.1")
		return True


def main(sdk, destination, arch):
	if not os.path.isdir(SHIM):
		raise SystemExit("run `make stubs` first: %s is missing" % SHIM)
	work = os.path.join(destination, ".work")
	os.makedirs(work, exist_ok=True)
	builder = Builder(sdk, arch, work)
	built = 0

	for relative in ("System/Library/Frameworks", "System/Library/PrivateFrameworks"):
		source_root = os.path.join(sdk, relative)
		if not os.path.isdir(source_root):
			continue
		for entry in sorted(os.listdir(source_root)):
			if not entry.endswith(".framework"):
				continue
			binary = os.path.join(source_root, entry, entry[:-len(".framework")])
			if os.path.isfile(binary) and builder.build(binary,
					os.path.join(destination, relative, entry,
						entry[:-len(".framework")])):
				built += 1

	source_root = os.path.join(sdk, "usr/lib")
	target_root = os.path.join(destination, "usr/lib")
	os.makedirs(target_root, exist_ok=True)
	for entry in sorted(os.listdir(source_root)):
		source = os.path.join(source_root, entry)
		target = os.path.join(target_root, entry)
		# Keep the symlink farm: -lz finds libz.dylib, which points at
		# libz.1.2.3.dylib, and the linker follows it exactly as it would in
		# the SDK.
		if os.path.islink(source):
			link = os.readlink(source)
			if os.path.lexists(target):
				os.remove(target)
			os.symlink(link, target)
		elif entry.endswith(".dylib") and builder.build(source, target):
			built += 1

	# The startup files are real objects, not stubs, and are small.
	for entry in sorted(os.listdir(source_root)):
		if entry.endswith(".o"):
			shutil.copy2(os.path.join(source_root, entry),
				os.path.join(target_root, entry))

	# GCC 4.2's Darwin spec names the Mac OS X flavours of the startup file and
	# the unwinder. iOS has neither name, only the one thing each is. The link
	# resolves through these; the install name still sends dyld to the real
	# library, and crt1.o is genuinely the same object.
	for alias, real in (("libgcc_s.10.4.dylib", "libgcc_s.1.dylib"),
			("libgcc_s.10.5.dylib", "libgcc_s.1.dylib"),
			("crt1.10.5.o", "crt1.o"),
			("crt1.10.6.o", "crt1.o")):
		target = os.path.join(target_root, alias)
		if os.path.exists(os.path.join(target_root, real)) and \
				not os.path.lexists(target):
			os.symlink(real, target)

	shutil.rmtree(work)
	print("%d stubs, %d symbols" % (built, builder.symbols))


if __name__ == "__main__":
	if len(sys.argv) != 4:
		raise SystemExit("usage: mkdevstubs.py <sdk> <destination> <arch>")
	main(*sys.argv[1:])
