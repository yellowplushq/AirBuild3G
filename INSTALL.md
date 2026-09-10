# Installing AirBuild3G — instructions for a coding agent

**This file is the installer.** Hand it, and this repository, to a coding
agent with a shell on a Mac, and let it work. It is written for an agent
rather than a person because everything below is a build with three
prerequisites and a dozen ways to go quietly wrong, and because the thing
being installed is itself a coding agent — it seems only fair.

A person can follow it too. Nothing here is magic.

---

## Goal

A jailbroken iPhone 3G or 3GS with AirBuild3G on the home screen, an API key
in its Settings, and a working on-device compiler — so that asking it for an
app produces an app, compiled and installed on that phone.

## What you need before starting

| | |
|---|---|
| A Mac | with Xcode and the Command Line Tools. Any recent Xcode; the whole point of this project is that the current one works. |
| `dpkg` and `ldid` | `brew install dpkg ldid`. Neither ships with macOS. `dpkg-deb` must be 1.19 or newer, which Homebrew's is. |
| The iOS 4.1 SDK | see below |
| A jailbroken iPhone 3G or 3GS | reachable over SSH, with Cydia Substrate installed. Every phone Legacy-iOS-Kit jailbreaks has Substrate already. |

The iPhone must be jailbroken. There is no way around this and it is not a
policy choice: installing on a stock device needs a provisioning profile
signed by a certificate chain an iOS 4 device still trusts, and no current
Apple developer certificate is one.

### The SDK

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks ~/theos-sdks
cd ~/theos-sdks && git sparse-checkout set iPhoneOS4.1.sdk
```

Then use `LEGACY_SDK=~/theos-sdks/iPhoneOS4.1.sdk` below. The default the
Makefile looks for is `~/theos/sdks/iPhoneOS4.1.sdk`, so if you already have
Theos installed you can leave `LEGACY_SDK` off entirely.

> **Pass `LEGACY_SDK` on the command line or export it — never assign it
> inside the Makefile.** `tools/fetch_payload.py` reads it from the
> environment itself. If it cannot see it, the payload is built *without*
> `sdk.tar.gz` and nothing complains until the phone tries to link something
> and fails with undefined `_objc_msgSend`.

---

## Step 1 — Build and check

```sh
make LEGACY_SDK=<sdk> && make LEGACY_SDK=<sdk> verify && make test
```

**Success looks like:** `verify` printing, for each of `AirBuild3G` and
`airbuildhelper`, for each of `armv6` and `armv7`:

```
LC_VERSION_MIN_IPHONEOS 4.0 ok
LC_UNIXTHREAD ok (iOS 4 dyld cannot load LC_MAIN)
method IMPs carry the Thumb bit ok      (armv7 only)
```

and `make test` printing five `PASS` lines.

Do not continue past a `verify` failure. Each of those three checks stands
for a way of producing a binary that builds cleanly and then cannot be loaded
at all by an iOS 4 device.

If `make` says `warning: ldid not found`, stop and install it. An unsigned
binary is SIGKILLed at launch, which on the phone looks exactly like the app
doing nothing when tapped.

## Step 2 — Build the packages

```sh
make LEGACY_SDK=<sdk> package
```

Downloads about 90 MB from `apt.saurik.com`, `apt.thebigboss.org` and one
GitHub release, checking every file against the sha256 pinned in
`Packaging/payload.lock`, and produces three `.deb` files in `build/`:

| package | for | size |
|---|---|---|
| `com.apple.airbuild.oss` | the app itself | under 1 MB |
| `com.apple.airbuild.oss.bootstrap4` | iPhone 3G/3GS on iOS 4 — armv6, GCC 4.2 | ~46 MB |
| `com.apple.airbuild.oss.bootstrap6` | iPhone 3GS on iOS 5/6 — armv7, clang | ~48 MB |

The two bootstraps `Conflicts` each other and are firmware-gated, so **a
phone gets exactly one**: `bootstrap4` below iOS 5, `bootstrap6` from iOS 5.
Check the phone's version (`sw_vers` over SSH, or Settings → General → About)
before you pick.

The download is cached in `build/payload/cache`; later builds are offline.

## Step 3 — Put it on the phone

```sh
make LEGACY_SDK=<sdk> install-device DEVICE=root@<phone-ip>
```

The default jailbreak login is `root` / `alpine`. This copies both debs, runs
`dpkg -i` detached, refreshes `uicache` as `mobile`, and restarts the app.
It takes several minutes on a 3G — dpkg rewrites its whole database on every
invocation and a 3G is a 2008 phone.

**Success looks like:** `AIRBUILD-INSTALL-DONE-0` in the log the script polls,
and an AirBuild icon on the home screen.

## Step 4 — Give it a key

On the phone: open AirBuild → **Settings** → **Endpoint**.

| field | what to put |
|---|---|
| Base URL | `https://api.anthropic.com/v1` (the default). Any endpoint that speaks OpenAI-format `/chat/completions` works — OpenRouter, or a llama.cpp server on the same Wi-Fi. |
| API Key | your own key. It is stored in this app's preferences on this phone and is sent to that endpoint and nowhere else. |
| Model | `claude-opus-5` (the default), or `claude-sonnet-5` if you would rather it cost less. |

Leave **Trust Any Certificate** off. It is there for a self-hosted endpoint
on your own network whose certificate iOS 4 cannot build a path for; turning
it on for a public endpoint means anyone who can answer for that address can
read your API key.

## Step 5 — Install the toolchain

On the phone: **Settings → Environment**. This unpacks the compiler and SDK
out of the bootstrap package and installs them. It is 20 minutes of dpkg on a
3G. It is idempotent — running it again on a finished phone returns
immediately, because it reads `/var/lib/dpkg/status` and skips everything
already at the pinned version.

**Success looks like:** every step green, and a "Welcome to AirBuild" alert.

## Step 6 — Prove it works

Start a project and ask for something small. The model gets four tools —
`Execute`, `EditFile`, `PatchFile`, `CheckBuild` — and a project seeded from a
template that already compiles. A green `CheckBuild` is the proof: that is
GCC 4.2 running on the phone, on the phone's own ARM11, compiling against SDK
headers rewritten so a 2008 compiler can parse them.

From the Mac, `make hello-device DEVICE=root@<phone-ip>` does the same thing
non-interactively.

---

## When it goes wrong

These are the failures this project has actually hit. Each looks like
something else, which is why they are written down.

**The app is installed, tapping it does nothing, and there is no crash
report.** Two causes, both of which leave no trace. Either the binary is
unsigned — check that `ldid` was present when you ran `make`, and rebuild if
it was not — or a `UIKitApplication` job outlived its process and still holds
the bootstrap name, so every launch exits before drawing. `Packaging/postinst`
removes it on every install, so reinstalling is the cure; by hand it is
`launchctl list` and then `launchctl remove` on the label.

**On-device linking fails with undefined `_objc_msgSend`.** The payload
shipped without `sdk.tar.gz`, because `tools/fetch_payload.py` could not see
`LEGACY_SDK`. Pass it on the `make` command line and rebuild the payload.

**`gcc: Internal error: Bus error (program cc1obj)`.** Something replaced the
pinned compiler with `iphone-gcc 4.2-20090304-1-9`. That build carries Apple's
precompiled-header arena as a gigabyte of `__DATA,__bss`, which puts `__common`
above `0x40000000` — and `VM_MAX_ADDRESS` on an armv6 iPhone is `0x30000000`,
so every `cc1*` backend takes SIGBUS before `main`. The lock pins the 2008
build, which has no arena at all. Both are Apple build 5555; nothing is lost.

**Cydia offers to upgrade `ldid` or `network-cmds`.** Do not take it. A newer
`ldid` on this phone cannot sign, and an unsigned binary is SIGKILLed at
launch — it ends the project. Everything the payload installs is marked
`hold`, which is the same flag Cydia's own "Ignore Upgrades" sets, so this
should not come up; if it does, something un-held them.

**`uicache` hangs, and SpringBoard restarts every two minutes.** AppSync is
installed. AppSync for iOS 4 patches `/usr/libexec/installd` and the kernel
then SIGKILLs it at every launch; `uicache`, `lsd` and SpringBoard's own
startup all wait on installd synchronously, so everything stops and the
watchdog kills SpringBoard on a timer. `launchctl list | grep installd` with a
signal in the status column confirms it. The cure is the stock `installd`
from the 8C148 root filesystem. **Nothing here needs AppSync** — every app
this project builds is a deb signed with `ldid` and installed by dpkg.

**`make package` fails with "offline: … is not in build/payload/cache".** The
cache is empty and `package` builds the payload offline. Run
`make LEGACY_SDK=<sdk> payload` once with a network first.

**HTTPS fails on the phone.** Stock iOS 4 SecureTransport speaks TLS 1.0
only; TLS 1.2 comes from TLSFix, a Substrate tweak the bootstrap ships and
Settings → Environment installs. No respring needed — the app loads it before
every request. If Substrate itself is missing, install it from the jailbreak
or Cydia; this repository ships no third-party binaries.

**Anything else on the phone.** `AGENTS.md` is the full working agreement for
this repository and is written for exactly this audience.
