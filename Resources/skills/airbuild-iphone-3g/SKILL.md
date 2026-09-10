---
name: airbuild-iphone-3g
description: >
  Build, package and install iOS software on an iPhone 3G from inside
  AirBuild, using the on-device GCC 4.2 toolchain. Covers the exact
  binary paths, a working compile/sign/package recipe, the iOS 4 API
  limits, and the Mac cross-build. Use when writing or installing an app
  or tweak on the 3G, or when /airbuild-iphone-3g is invoked.
---

# Building on the iPhone 3G

You are running on the phone. You compile here; you do not cross-compile from
a Mac. Your tools are `Execute` (a root shell whose working directory is
already the project you were opened with), `EditFile`, `PatchFile` and
`CheckBuild` (`make`, with the toolchain environment sourced for you).

**Write files with `EditFile` and `PatchFile`.** A heredoc through `Execute` is
a quoting problem you have to get right on the first try, and a turn is only
sixteen rounds. Build with `CheckBuild` rather than by remembering the flags.

iOS 4.2.1, custom firmware, **armv6**, 128 MB RAM, one core.

## Toolchain — absolute paths

Everything is a real path on this device. `. /etc/profile.d/airbuild.sh` puts
the first group on `PATH` and sets the variables; `Execute` does not run a
login shell, so source it before anything else. `CheckBuild` has already done
it for you.

| What | Path |
|---|---|
| C / Objective-C compiler | `/usr/bin/gcc` → `/usr/bin/arm-apple-darwin9-gcc` → `arm-apple-darwin9-gcc-4.2.1` |
| C++ | `/usr/bin/g++`, `/usr/bin/c++` → `/usr/bin/arm-apple-darwin9-g++` |
| Preprocessor | `/usr/bin/cpp` → `/usr/bin/arm-apple-darwin9-cpp` |
| Linker | `/usr/bin/ld` → `/usr/bin/ld64` (also `/usr/bin/ld_classic`) |
| Assembler | `/usr/bin/as` |
| Signing | `/usr/bin/ldid` |
| Archives | `/usr/bin/ar`, `/usr/bin/ranlib` |
| Mach-O tools | `/usr/bin/otool`, `/usr/bin/nm`, `/usr/bin/strip`, `/usr/bin/lipo`, `/usr/bin/install_name_tool`, `/usr/bin/codesign_allocate` |
| Make | `/usr/bin/make` (GNU Make 3.81) |
| Packaging | `/usr/bin/dpkg`, `/usr/bin/dpkg-deb` |
| Launcher / cache | `/usr/bin/uiopen`, `/usr/bin/uicache` |
| Also present | `/usr/bin/git`, `/usr/bin/tar`, `/usr/bin/gzip`, `/usr/bin/find`, `/usr/bin/gawk`, `/bin/sed`, `/bin/grep` |

`gcc`, `cc`, `g++`, `c++` and `cpp` are symlinks AirBuild creates — Telesphoreo's
`iphone-gcc` ships only the `arm-apple-darwin9-*` names, and without the
symlinks every ordinary Makefile fails with `gcc: command not found`.

| Variable | Value |
|---|---|
| `$SDKROOT` | `/var/airbuild/toolchain/sdks/iPhoneOS4.1.sdk` |
| `$IOS_CFLAGS` | the compile flags — pass them, do not retype them |
| `$IOS_LDFLAGS` | the link flags — same |
| `$CPATH` | `/usr/lib/gcc/arm-apple-darwin9/4.2.1/include` |
| project | `/var/airbuild/projects/<uuid>/project/` — your working directory |

**Use `$IOS_CFLAGS` and `$IOS_LDFLAGS`.** They exist because three things about
this phone are not obvious, and getting any of them wrong fails in a way that
looks like your code is broken:

- `-isysroot` hides the compiler's own `stdarg.h`, because it prefixes the
  built-in include path too and the SDK has no copy there. `$CPATH` puts it
  back.
- The SDK's libraries are **stubs**: the real install name and the real
  symbol names, and no code at all. Since iOS 3.1 every system library lives
  in the dyld shared cache and
  `/System/Library/Frameworks/Foundation.framework` holds an Info.plist and
  nothing else, so there is nothing on this phone to link against. The link is
  otherwise ordinary, which is the point — **a framework you forget to pass is
  a link error**, not a binary that installs and then dies at launch with
  `Symbol not found`.
- `$IOS_LDFLAGS` already carries `-lobjc` and `-framework CoreFoundation`.
  This driver adds neither when its input is a `.o`, and `objc_msgSend` and
  `___CFConstantStringClassReference` are in them.
- Compile and link are **separate commands**, because they need different
  flags: headers from the SDK, symbols from dyld.

If `/etc/profile.d/airbuild.sh` or `/usr/bin/gcc` is missing, the environment
has not been installed: tell the user to open **Settings → Environment** and
tap Install. Do not try to install a compiler yourself.

## The template is already in your project

AirBuild copies the single-view app in `template/` into every new project and
resolves its placeholders, so `src/main.m`, `src/AppDelegate.{h,m}`,
`src/RootViewController.{h,m}`, `Info.plist` and a `Makefile` are already
there, already named after the project, and already compile. The whole tree is
quoted in your system prompt — you do not need to list it or read it back.

Edit `src/RootViewController.m`; everything else is scaffolding you rarely
touch. The template already gets right the things that fail at *runtime* rather
than at compile time here — manual retain/release, no blocks, 4.0-only
selectors probed, frame layout, a URL scheme, gzip debs — so editing it beats
rediscovering them.

```
CheckBuild                     # make
CheckBuild target=install      # compile, sign, package, dpkg -i, uicache
Execute make run               # uiopen myapp://
```

`scripts/new-app.sh` does the same copy by hand, for a *second* app inside one
project. A project you were opened with does not need it.

## Build an app by hand

The template's Makefile is this, if you would rather run it yourself. There
is no Theos on this phone and nothing needs one.

```sh
. /etc/profile.d/airbuild.sh

gcc -c $IOS_CFLAGS main.m -o main.o
gcc main.o -o MyApp $IOS_LDFLAGS \
	-framework UIKit -framework Foundation -framework CoreGraphics
ldid -S MyApp
```

No `-arch`: this compiler emits armv6 and its driver does not take Apple's
flag. Link UIKit even for a command-line tool — a Foundation-only binary from
this toolchain is SIGKILLed at launch on a 3G.

`scripts/build-app.sh` does exactly this, plus packaging and install, if you
would rather call one thing:

```sh
sh /Applications/AirBuild3G.app/skills/airbuild-iphone-3g/scripts/build-app.sh \
	MyApp com.example.myapp main.m
```

Then package and install:

```sh
mkdir -p layout/Applications/MyApp.app layout/DEBIAN
cp MyApp layout/Applications/MyApp.app/
# ... write Info.plist and DEBIAN/control ...
dpkg-deb -Zgzip -b layout myapp.deb    # gzip: this dpkg cannot unpack xz
dpkg -i myapp.deb
su mobile -c uicache                   # uicache refuses root on this firmware
uiopen myapp://                        # a URL — see below
```

**`uiopen` takes a URL and nothing else.** `uiopen com.example.myapp` is not a
launch; it puts an "unsupported URL" prompt on the screen and returns 0. Give
the app a scheme in `Info.plist` and open that:

```xml
<key>CFBundleURLTypes</key>
<array>
	<dict>
		<key>CFBundleURLName</key><string>com.example.myapp.open</string>
		<key>CFBundleURLSchemes</key><array><string>myapp</string></array>
	</dict>
</array>
```

`Info.plist` needs at least `CFBundleExecutable`, `CFBundleIdentifier`,
`CFBundleName`, `CFBundlePackageType` (`APPL`) and `MinimumOSVersion` (`4.0`).
`DEBIAN/control` needs `Package`, `Version`, `Architecture: iphoneos-arm`,
`Description`, `Maintainer`, `Author`, `Section`, `Depends: firmware (>= 4.0)`.

### Installing is not proof it works

A binary whose symbols dyld cannot bind installs cleanly, launches, and is
killed before `main`. Check, rather than assume:

```sh
( /Applications/MyApp.app/MyApp > /tmp/launch.log 2>&1 & )
sleep 6; killall MyApp
cat /tmp/launch.log
```

Backgrounded and killed, because an app that starts correctly enters its run
loop and never returns — one that dyld rejected is already gone. An empty log
is a pass. `dyld: Symbol not found: …` means the link was wrong, and the usual
cause is a `-framework` you did not pass. `Couldn't register … with the
bootstrap server` is also a pass: it means every symbol bound and
`UIApplicationMain` was entered, and only SpringBoard may own the name.

`make run` (or `uiopen <scheme>://`) is what actually puts it on the screen.

If the icon is there and tapping it does nothing — no window, no crash report
— the app is not crashing. Its `launchd` job outlived a previous run, so the
bootstrap name is taken and every launch exits immediately:

```sh
launchctl list | grep com.example.myapp     # a line with no pid
launchctl remove 'UIKitApplication:com.example.myapp[0x1234]'
```

Reinstalling AirBuild itself clears its own; nothing clears yours but this.

Details and the setuid-wrapper trick for a root app:
[packaging.md](references/packaging.md).

## Redirect the build, always

`Execute` returns at most **64 KB** and the tool loop is **16 rounds**.
`CheckBuild` hands back only the tail of a build for exactly this reason. A
command of your own that prints more than that costs you the log and the round:

```sh
make -j1 > /tmp/build.log 2>&1
echo EXIT:$?
tail -c 40000 /tmp/build.log
```

One job at a time. This phone has 128 MB of RAM and one core.

Write files with `EditFile`, not with `cat > path <<'EOF'` and never one
`echo` per line — rounds are the scarce resource.

## What this compiler is

GCC 4.2, triple `arm-apple-darwin9`, C++98, Objective-C 2.0. Inside that:

- **no ARC** — manual `retain`/`release`, always
- **no blocks**, no Objective-C literals (`@[]`, `@{}`, `@42`), no autosynthesis.
  Blocks arrived in Apple GCC build 5646; this is build 5555. The SDK headers
  have had their block declarations removed for exactly this reason, so
  `UIView`'s `animateWithDuration:animations:` and friends are not declared
  here. Use `beginAnimations:context:` / `commitAnimations` instead.
- **no `@autoreleasepool`** — use `NSAutoreleasePool` and `-release`
- **iOS 4.0 APIs only.** Anything newer compiles against these headers and
  crashes at runtime. `-viewDidLayoutSubviews` is iOS 5;
  `UIAlertViewStylePlainTextInput` is iOS 5; `-headerViewForSection:` is iOS 6.
- **no perl, and no Theos.** Logos (`.x`/`.xm`) is a perl program and the
  only perl in either repository is armv7 declaring iOS 4.3, so neither is
  installed. Everything here is plain `.m` compiled with `gcc`; for a tweak,
  hook with `MSHookMessageEx` directly. Do not go looking for `$THEOS` — it
  does not exist, and nothing needs it.

## Where things live

```
/var/airbuild/projects/<uuid>/project/   your working tree
/var/airbuild/projects/<uuid>/manifest.plist    AirBuild owns it — do not edit
/var/airbuild/projects/<uuid>/conversation/     this transcript — do not edit
/var/airbuild/toolchain/sdks/            $SDKROOT lives here
/var/airbuild/bootstrap/                 the payload the Environment page installs
/etc/profile.d/airbuild.sh               PATH, SDKROOT, IOS_CFLAGS, IOS_LDFLAGS
```

Write source in the project directory. It survives relaunch and it is what the
user sees in the project list. Do not write into `/tmp` or `/var/mobile`.

`/` has about 100 MB free and `/private/var` has gigabytes. Anything large
belongs under `/var/airbuild`.

## What not to do

- Do not upgrade the toolchain, and do not unhold it. `apt-get` and Cydia both
  work here, and both offer a newer `ldid` (`1:1.2.1`, built for iOS 5 and
  armv7). Taking it ends everything: nothing can be signed, and an unsigned
  binary is SIGKILLed at launch. Every package AirBuild installed is marked
  `hold` for this reason — the same flag Cydia's "Ignore Upgrades" sets. Leave
  it. Saurik still ships packages built for much newer firmware generally, and
  installing them replaces working iOS 4 binaries with ones that reference
  symbols this OS does not have.
- Do not trust `apt-get -s dist-upgrade` when it says there is nothing to do.
  One unmet dependency anywhere makes apt abandon the whole calculation, so it
  answers "0 upgradable" on a phone with pending upgrades. `apt-cache policy
  <pkg>` per package is the honest answer.
- Do not pack debs with xz. `dpkg -Zgzip`, always.
- Do not run `lipo`. odcctools' build of it references `_map_fd`, which this
  `libSystem` does not export, so it traps instead of printing. Use `file` or
  `otool -h`.
- Do not believe `nm` about the SDK's link stubs. odcctools' `nm` is from 2008
  and rejects them as `malformed object (unknown load command 4)`; `ld` reads
  them perfectly well. `nm` on your own `.o` files is fine.
- Do not run `uicache` as root — `su mobile -c uicache`.
- Do not stash by hand. AirBuild's Environment page verifies the copy before
  it swaps in the symlink and keeps the original as `<path>.airbuild-old`
  forever. A hand-rolled stash that half-succeeds is a phone that will not
  boot. Recovery over SSH is
  `rm /usr/libexec && mv /usr/libexec.airbuild-old /usr/libexec`.
- Do not re-enable certificate validation in `ABLChatClient` or remove
  `ABLTrustAll.m`. iOS 4.2.1 cannot validate today's chains even with TLSFix.
- Do not uninstall `com.skyglow.tlsfix`. CFNetwork TLS 1.2 comes from it.
- Do not edit a project's `manifest.plist` or `conversation/`.

## Scripts

At `/Applications/AirBuild3G.app/skills/airbuild-iphone-3g/scripts/`:

| Script | What it does |
|---|---|
| `new-app.sh <Name> <bundle-id> [scheme]` | copy the single-view template into the current directory; then `make install` |
| `build-app.sh <name> <bundle-id> <source...>` | compile, link, sign, package and install a UIKit app; prints the deb path |
| `check-toolchain.sh` | one line per tool saying whether it works; run this first when a build fails for no clear reason |
| `truststore_insert.py` | add a CA to the iOS 4 trust store |

`template/` next to them is the app skeleton `new-app.sh` copies.

## Other references

- [packaging.md](references/packaging.md) — debs, setuid wrapper, `uicache`
- [device.md](references/device.md) — SSH, apt, clock
- [certificates.md](references/certificates.md) — the three separate TLS stacks
- [project-layout.md](references/project-layout.md) — iOS 4 code and UI rules
- [mac-build.md](references/mac-build.md) — the Xcode 27 armv6 cross-build,
  which is a different toolchain with different rules

On the phone these are at
`/Applications/AirBuild3G.app/skills/airbuild-iphone-3g/`. This file is in
the system prompt; the references are not — `Execute` to read them.
