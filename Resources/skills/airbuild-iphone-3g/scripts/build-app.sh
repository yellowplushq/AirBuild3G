#!/bin/sh
# Compile, link, sign, package and install a UIKit app on this phone.
#
#   build-app.sh <name> <bundle-id> <source.m> [more.m ...]
#
# Everything here is the recipe from SKILL.md; it exists so a build is one
# command rather than six, and so the flags that are easy to get wrong come
# from the environment rather than from memory.

set -e

if [ $# -lt 3 ]; then
	echo "usage: build-app.sh <name> <bundle-id> <source.m> [more.m ...]" >&2
	exit 2
fi

NAME=$1
BUNDLE=$2
shift 2
# uiopen takes a URL and nothing else, so an app with no scheme cannot be
# launched from a script at all.
SCHEME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

. /etc/profile.d/airbuild.sh
[ -n "$SDKROOT" ] || { echo "environment not installed: Settings > Environment" >&2; exit 1; }

WORK=$(pwd)
BUILD=$WORK/.build
rm -rf "$BUILD"
mkdir -p "$BUILD"

# One job, one file at a time: 128 MB and one core.
objects=""
for source in "$@"; do
	object="$BUILD/$(basename "$source" | sed 's/\.[^.]*$//').o"
	echo "compile $source"
	gcc -c $IOS_CFLAGS "$source" -o "$object"
	objects="$objects $object"
done

echo "link $NAME"
gcc $objects -o "$BUILD/$NAME" $IOS_LDFLAGS \
	-framework UIKit -framework Foundation -framework CoreGraphics

# Unsigned is SIGKILL on launch, not a warning.
ldid -S "$BUILD/$NAME"

LAYOUT=$BUILD/layout
mkdir -p "$LAYOUT/Applications/$NAME.app" "$LAYOUT/DEBIAN"
cp "$BUILD/$NAME" "$LAYOUT/Applications/$NAME.app/"

cat > "$LAYOUT/Applications/$NAME.app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>4.0</string>
	<key>UIPrerenderedIcon</key><true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>$BUNDLE.open</string>
			<key>CFBundleURLSchemes</key><array><string>$SCHEME</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

cat > "$LAYOUT/DEBIAN/control" <<CONTROL
Package: $BUNDLE
Name: $NAME
Version: 1.0.0
Architecture: iphoneos-arm
Description: Built on an iPhone 3G with AirBuild.
Maintainer: AirBuild
Author: AirBuild
Section: Applications
Depends: firmware (>= 4.0)
CONTROL

# gzip: this dpkg cannot unpack anything else.
dpkg-deb -Zgzip -b "$LAYOUT" "$BUILD/$NAME.deb" >/dev/null
dpkg -i "$BUILD/$NAME.deb"
# uicache refuses root on this firmware.
su mobile -c uicache

# Installing is not proof. A binary whose symbols dyld cannot bind installs,
# launches and is killed before main — which is what a wrong -framework list
# produces, and it looks exactly like success from here.
#
# Backgrounded and killed rather than run: an app that starts correctly enters
# its run loop and never returns.
( "/Applications/$NAME.app/$NAME" > "$BUILD/launch.log" 2>&1 & )
sleep 6
killall "$NAME" 2>/dev/null || true
if grep -q "Symbol not found\\|dyld:" "$BUILD/launch.log"; then
	head -3 "$BUILD/launch.log" >&2
	echo "FAILED: dyld could not bind $NAME — check the -framework list" >&2
	exit 1
fi

echo "installed $BUNDLE — uiopen $SCHEME://"
echo "$BUILD/$NAME.deb"
