#!/usr/bin/env python3
"""Cut blocks out of SDK headers so GCC 4.2 can read them.

The on-device compiler is Apple GCC 4.2 (build 5555, 2008). Blocks arrived a
year later in build 5646, so no front end here — C, C++, ObjC or ObjC++ —
accepts a `^`:

	error: expected identifier or '(' before '^' token

The iPhoneOS 4.1 headers declare blocks unguarded (UIView's
animateWithDuration:animations: is not behind NS_BLOCKS_AVAILABLE), so a single
`#import <UIKit/UIKit.h>` fails on a phone that is otherwise perfectly able to
run the resulting app. Dropping those declarations leaves the iOS 3-era API
surface, which is what a compiler of this vintage could ever have targeted
anyway, and iOS 4 runs iOS 3 binaries.

Only whole declarations go: a block appears in a method, function or typedef,
each of which ends at a semicolon, so the declaration containing it is removed
entirely rather than left half-formed. C++ headers are skipped — valarray's
`_DEFINE_VALARRAY_OPERATOR(^, __bitwise_xor)` is the xor operator, not a block,
and nothing in libstdc++ has blocks in it.

A typedef that goes takes its users with it. `typedef NSComparisonResult
(^NSComparator)(id, id)` is a block declaration and is dropped, but
`- (void)sortUsingComparator:(NSComparator)cmptr` is not, and a header that
names a type nobody declared does not parse either ("expected a type",
eighteen times over between NSArray.h, NSSortDescriptor.h and dispatch/).
So the names of every typedef removed are collected and the headers are
walked again, until a pass removes nothing new.
"""

import os
import re
import sys

# `(^)` and `(^name)` are blocks; `(^,` and `(^ ,` are a macro argument.
BLOCK = re.compile(r"\(\s*\^\s*[A-Za-z_][A-Za-z0-9_]*\s*\)|\(\s*\^\s*\)")
# Lines that are structure rather than declaration, and end any run.
STRUCTURAL = re.compile(r"^\s*(#|//|/\*|\*|@interface|@protocol|@end|@class|\})")
# The name a removed typedef declared: `(^Name)` for a block type, or the
# last identifier before the semicolon for anything built on one.
TYPEDEF_BLOCK = re.compile(r"\btypedef\b[^;]*?\(\s*\^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")
TYPEDEF_PLAIN = re.compile(r"\btypedef\b[^;]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*;")
# GCC 4.2 does not merely warn about these, it errors:
#   NSString.h:282: error: format string argument follows the args to be formatted
# The definitions are behind `#if !defined`, so emptying them is enough.
FORMAT_ATTRIBUTE = re.compile(
	r"^(\s*#\s*define\s+NS_FORMAT_(?:FUNCTION|ARGUMENT)\([^)]*\))\s+__attribute__.*$",
	re.MULTILINE)


def sanitize(text, names=frozenset()):
	"""Drop every declaration that mentions a block or one of `names`.

	Returns (text, count, dropped): the rewritten header, how many
	declarations went, and the names of the typedefs among them.
	"""
	mentions = re.compile(r"\b(?:%s)\b" % "|".join(sorted(names))) if names else None
	out, pending, removed, dropped = [], [], 0, set()
	for line in text.splitlines(True):
		if STRUCTURAL.match(line):
			out.extend(pending)
			pending = []
			out.append(line)
			continue
		pending.append(line)
		if ";" not in line:
			continue
		declaration = "".join(pending)
		if BLOCK.search(declaration) or (mentions and mentions.search(declaration)):
			removed += 1
			match = TYPEDEF_BLOCK.search(declaration) or TYPEDEF_PLAIN.search(declaration)
			if match:
				dropped.add(match.group(1))
		else:
			out.extend(pending)
		pending = []
	out.extend(pending)
	return "".join(out), removed, dropped


def headers(root):
	for base, dirs, names in os.walk(root):
		# libstdc++ has no blocks, and its `^` is the xor operator.
		dirs[:] = [d for d in dirs if d != "c++"]
		for name in names:
			if not name.endswith((".h", ".hpp")):
				continue
			path = os.path.join(base, name)
			# The headers-only copy leaves symlinks whose targets were not
			# packed; there is nothing to rewrite in a dangling link anyway.
			if os.path.islink(path) or not os.path.isfile(path):
				continue
			yield path


def walk(root):
	"""Returns (files changed, declarations removed, typedef names removed)."""
	changed, total, names = set(), 0, set()
	while True:
		mentions = re.compile(r"\b(?:%s)\b" % "|".join(sorted(names))) if names else None
		found = set()
		for path in headers(root):
			with open(path, "r", errors="surrogateescape") as handle:
				text = handle.read()
			if BLOCK.search(text) or (mentions and mentions.search(text)):
				cleaned, removed, dropped = sanitize(text, names)
				found |= dropped
			else:
				cleaned, removed = text, 0
			cleaned, attributes = FORMAT_ATTRIBUTE.subn(r"\1", cleaned)
			removed += attributes
			if not removed:
				continue
			with open(path, "w", errors="surrogateescape") as handle:
				handle.write(cleaned)
			total += removed
			changed.add(path)
		if found <= names:
			return len(changed), total, sorted(names)
		names |= found


if __name__ == "__main__":
	if len(sys.argv) != 2:
		raise SystemExit("usage: sanitize_sdk.py <sdk-root>")
	changed, declarations, names = walk(sys.argv[1])
	print("removed %d block declarations from %d headers" % (declarations, changed))
	if names:
		print("and every use of %s" % ", ".join(names))
