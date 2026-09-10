#!/bin/sh
# Runs ON the phone. Builds a UIKit app with the toolchain AirBuild installed,
# packages it, installs it and launches it.
#
# This is the end-to-end proof that the environment is a working toolchain and
# not just a pile of unpacked debs. tools/hello_device.sh copies this over and
# runs it; it is a separate file rather than a heredoc so the Objective-C in it
# is not fighting two levels of shell quoting.

set -e

. /etc/profile.d/airbuild.sh

# The ios6 payload installs clang and no gcc at all, so the compiler is
# discovered rather than assumed.
CC=$(command -v gcc || command -v clang)
[ -n "$CC" ] || { echo "no compiler on PATH; run Settings > Environment"; exit 1; }

WORK=/var/airbuild/projects/hello-e2e/project
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "== toolchain =="
echo "cc:     $CC"
echo "ld:     $(command -v ld || echo MISSING)"
echo "ldid:   $(command -v ldid || echo MISSING)"
echo "make:   $(command -v make || echo MISSING)"
echo "SDKROOT=$SDKROOT"

cat > main.m <<'SOURCE'
#import <UIKit/UIKit.h>

// iOS 4.0 API only, manual retain/release: this compiler is GCC 4.2, with no
// ARC, no blocks and no Objective-C literals.
@interface HelloDelegate : NSObject <UIApplicationDelegate> {
	UIWindow *_window;
}
@end

@implementation HelloDelegate

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)options {
	_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

	UILabel *label = [[UILabel alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	[label setText:@"Built on the phone"];
	[label setTextAlignment:UITextAlignmentCenter];
	[label setBackgroundColor:[UIColor whiteColor]];
	[_window addSubview:label];
	[label release];

	[_window makeKeyAndVisible];
	return YES;
}

- (void)dealloc {
	[_window release];
	[super dealloc];
}

@end

int main(int argc, char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	int status = UIApplicationMain(argc, argv, nil, @"HelloDelegate");
	[pool release];
	return status;
}
SOURCE

# Compiling and linking take different flags and so are separate steps. The
# headers come from the SDK; the symbols do not — every system library on this
# phone lives in the dyld shared cache, so the SDK ships stubs that carry the
# real install names and symbol names and no code. $IOS_CFLAGS and
# $IOS_LDFLAGS spell both out and come from /etc/profile.d/airbuild.sh.
echo "== compile =="
"$CC" -c $IOS_CFLAGS main.m -o main.o
ls -l main.o

echo "== link =="
"$CC" main.o -o AirBuildHello $IOS_LDFLAGS \
	-framework UIKit -framework Foundation -framework CoreGraphics
ls -l AirBuildHello
# No lipo: odcctools' build of it references _map_fd, which this libSystem does
# not have, so it traps rather than printing anything. `file` says enough.
file AirBuildHello 2>/dev/null || true

echo "== sign =="
ldid -S AirBuildHello
echo "signed"

echo "== package =="
rm -rf layout
mkdir -p layout/Applications/AirBuildHello.app layout/DEBIAN
cp AirBuildHello layout/Applications/AirBuildHello.app/

cat > layout/Applications/AirBuildHello.app/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AirBuildHello</string>
	<key>CFBundleIdentifier</key><string>com.apple.airbuild.oss.hello</string>
	<key>CFBundleName</key><string>Hello</string>
	<key>CFBundleDisplayName</key><string>Hello</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>4.0</string>
	<key>UIPrerenderedIcon</key><true/>
	<!-- uiopen takes a URL and nothing else, so launching this from a script
	     needs a scheme of its own. -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>com.apple.airbuild.oss.hello.open</string>
			<key>CFBundleURLSchemes</key><array><string>airbuildhello</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

cat > layout/DEBIAN/control <<'CONTROL'
Package: com.apple.airbuild.oss.hello
Name: Hello
Version: 1.0.0
Architecture: iphoneos-arm
Description: Built on an iPhone 3G by AirBuild.
Maintainer: AirBuild
Author: AirBuild
Section: Applications
Depends: firmware (>= 4.0)
CONTROL

# gzip, not xz: the dpkg on this phone cannot unpack anything else.
dpkg-deb -Zgzip -b layout hello.deb
ls -l hello.deb

echo "== install =="
dpkg -i hello.deb
# uicache refuses root on this firmware, so it goes through mobile.
su mobile -c uicache
echo "installed"

echo "== dyld =="
# Launching is not the test; binding is. A binary whose symbols dyld cannot
# resolve installs and launches and is killed before main, and this script used
# to call that a pass — it is exactly what the empty link stubs produced.
#
# Run the binary directly and read what dyld says. SpringBoard owns the app's
# bootstrap name, so UIKit refuses to register a second one; reaching that
# message means every symbol bound and UIApplicationMain was entered, which is
# all this can prove from a shell.
# Backgrounded and killed rather than run: an app that starts correctly enters
# its run loop and never returns. An app dyld could not bind is already gone.
LAUNCH_LOG=$WORK/launch.log
( "/Applications/AirBuildHello.app/AirBuildHello" > "$LAUNCH_LOG" 2>&1 & )
sleep 6
killall AirBuildHello 2>/dev/null || true
cat "$LAUNCH_LOG"
if grep -q "Symbol not found\|dyld:" "$LAUNCH_LOG"; then
	echo "FAILED: dyld could not bind this binary"
	exit 1
fi
echo "every symbol bound"

echo "== launch =="
uiopen airbuildhello://
