#!/bin/sh
# Copy the single-view app template into the current directory.
#
#   new-app.sh <Name> <bundle-id> [scheme]
#
# Start every app this way rather than from an empty file. The template
# already gets right the things that fail at runtime rather than at compile
# time on this phone: manual retain/release, no blocks, iOS 4.0 selectors,
# frame layout, a URL scheme so `uiopen` works, and gzip debs.

set -e

if [ $# -lt 2 ]; then
	echo "usage: new-app.sh <Name> <bundle-id> [scheme]" >&2
	exit 2
fi

NAME=$1
BUNDLE=$2
# uiopen needs a URL, so an app that has no scheme cannot be launched from a
# script at all. Default it to the name, lowercased.
SCHEME=${3:-$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')}

TEMPLATE=$(dirname "$0")/../template
[ -d "$TEMPLATE" ] || { echo "template missing at $TEMPLATE" >&2; exit 1; }

if [ -e Makefile ] || [ -e src ]; then
	echo "refusing to overwrite: this directory already has a Makefile or src/" >&2
	exit 1
fi

cp -R "$TEMPLATE"/. .
rm -f README.md

# Every placeholder is resolved here and nowhere else. Leaving them for the
# Makefile to substitute at package time does not work: this same loop would
# rewrite the sed commands doing it, `s/__NAME__/$(NAME)/g` becomes
# `s/MyApp/MyApp/g`, and the app ships with CFBundleExecutable still reading
# __NAME__ — installed, on the springboard, and unable to find its own binary.
for file in Makefile Info.plist src/RootViewController.m; do
	sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE__/$BUNDLE/g" \
		-e "s/__SCHEME__/$SCHEME/g" "$file" > "$file.new"
	mv "$file.new" "$file"
done

echo "$NAME ($BUNDLE, $SCHEME://) — edit src/RootViewController.m, then: make install"
