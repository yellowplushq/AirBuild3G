# AirBuild3G

UIKit coding-agent client targeting **iOS 4.0** on **iPhone 3G (armv6)** and
**iPhone 3GS (armv7)**, built with the current Xcode toolchain. Read `README.md`
for the full rationale; this file is the short version for working in the repo.

Bring your own key: three settings — base URL, API key, model — and requests
go straight from the phone to that endpoint. There is no server of ours, no
account, and no device identity. See `ABLConfig.h`.

## Build

`make` (app **and** `airbuildhelper`, the setuid binary beside it),
`make verify` (arch + load-command check, both binaries), `make test`,
`make e2e` (a real conversation with a real endpoint — needs network and
spends the key's money, so it is not part of `make test`),
`make e2e-device` (the same conversation built armv6 for the phone),
`make deb`, `make ipa`, `make package` (the app deb and both payloads, built
offline from `build/payload/cache` and checked for completeness — all three are
byte-identical between builds of the same commit, verified against a fresh
clone),
`make payload` (both build-environment packages: downloads and verifies every
pinned deb, packs the SDK headers, writes each install plan;
`make payload-ios4` / `payload-ios6` build one),
`make install-device` (copy and install both debs on `$(DEVICE)`),
`make hello-device` (compile, package, install and launch a UIKit app on the
phone using only the toolchain it installed — the real end-to-end test),
`make payload-lock` (re-resolve versions against both repositories and rewrite
`Packaging/payload.lock` — review the diff, it decides which compiler a phone
gets), `make payload-from-device` (the same, plus everything already installed
on `$(DEVICE)`),
`make clean`, `make distclean`.
Overrides: `make LEGACY_SDK=...`, `make DEVICE=root@host`,
`make e2e E2E_ARGS="https://api.anthropic.com/v1 $KEY [model]"` (or set
`ANTHROPIC_API_KEY` in the environment).

**`LEGACY_SDK` must reach the environment, not just the Makefile.**
`tools/fetch_payload.py` reads it itself; a value only assigned inside the
Makefile leaves it unset there, and the payload ships with no `sdk.tar.gz` —
which fails much later, as undefined `_objc_msgSend` on the phone. Pass it on
the command line (`make LEGACY_SDK=... package`) or export it.

Two packages install on the phone: `com.apple.airbuild.oss` (the app) and one
payload — `com.apple.airbuild.oss.bootstrap4` (armv6, GCC 4.2, ~46 MB) or
`com.apple.airbuild.oss.bootstrap6` (armv7, clang, ~48 MB). They `Conflicts` each
other and are firmware-gated `(>= 4.0), (<< 5.0)` and `(>= 5.0)`, so a phone
holds exactly one; both unpack to `/var/airbuild/bootstrap` and install
nothing by themselves — Settings → Environment does that.

## Testing

`make test` and `make verify` are the host-side checks and neither needs a
device. Everything else is a jailbroken iPhone 3G or 3GS over SSH: install the
Debian package and refresh `uicache` as `mobile`. An iPhone 3G on iOS 4.2.1
with custom firmware is the reference device for the armv6 slice.

There is no desktop emulator worth using here. Probe 4.0-only selectors with
`respondsToSelector:` and keep a 3.x fallback anyway — `HelloAppDelegate`
shows the pattern — because that is also what makes the app survive a phone
older than the SDK it was built against.

## Non-obvious constraints

Xcode 27 has only the iOS 27 SDK, and its linker blocks a 4.0 target three ways.
Clang itself is fine — it still emits armv6/armv7 and accepts
`-mios-version-min=4.0`. Every workaround is in the `Makefile` and `tools/`:

- **Never link against the legacy SDK's dylibs.** They predate
  `LC_VERSION_MIN_IPHONEOS`, so `ld` calls their platform `unknown` and errors.
  Link against the generated `.tbd` tree in `build/sdkshim` instead
  (`-F`/`-L`), while `-isysroot` still points at the real SDK for headers.
  Adding a framework means adding it to `FRAMEWORKS` — the stub tree already
  covers the whole SDK.
- **Never set a link-time deployment target below 4.3.** `ld` refuses 4.0, 4.1
  and 4.2 by name. Compile at 4.0, link at 5.0 — 4.3 links too, but 5.0 is what
  has been run on device — then `tools/patch_minos.py` stamps it back.
- **Never pass `-arch armv6` to the linker.** It refuses. armv6 objects are
  compiled for real, relabelled armv7 for the link, then relabelled back
  (`tools/relabel_arch.py`), and `lipo`'d with the armv7 slice.
- **Keep `-Wl,-no_pie`.** iOS had no ASLR before 4.3, and the only machine code
  `ld` contributes to these binaries is the symbol stubs, which must stay plain
  ARM for the armv6 relabel to be safe. The stubs `ld-27037.1` emits are
  `ldr`/`add` with or without the flag — linking the same objects both ways at
  every target from 4.3 to 9.0 gives byte-identical `__picsymbolstub5` sections
  and differs only in the `MH_PIE` header bit — so do not trust the flag for
  this: `make verify` disassembles the armv6 slice and fails on any
  `movw`/`movt`, which is the property that actually matters.
- **Keep `-Wl,-no_objc_category_merging`.** ld-27037.1 folds a category into
  its class by default when both are in the image — `ABLProject` and
  `ABLProject(ABLProjectStoreSorting)` are — and the method list it writes
  for the merged class carries no Thumb bit on any IMP. The armv7 slice is
  Thumb, so on a 3GS the first message to an instance method of that class
  (`[project conversationDirectory]`, while creating one) enters Thumb code in
  ARM mode and dies at `pc 0x0` on a background thread. armv6 is all ARM,
  which is why the 3G never showed it. `make verify` fails on any even IMP in
  the armv7 slice.
- **The clang driver does not auto-link the ObjC runtime when given only `.o`
  inputs**, hence the explicit `-lobjc` and `-framework CoreFoundation`
  (which is where `_OBJC_CLASS_$_NSObject` and
  `___CFConstantStringClassReference` live in this SDK).

## Installing on a phone

`make install-device DEVICE=root@<ip>` is the whole install path:
`tools/deploy_device.sh` copies the app deb and the one bootstrap the phone's
firmware takes, runs `dpkg -i`, refreshes `uicache` as mobile, and restarts
the app. `INSTALL.md` is the same thing written as instructions for a coding
agent, which is how this project is meant to be installed. What is not
obvious:

- **dpkg is detached by hand** — `trap '' HUP`, stdin from `/dev/null`,
  output to a log — and **never with `nohup`**, which is coreutils and absent
  from a phone that has not run the Environment page. The script polls
  `/tmp/airbuild-install.log` for `AIRBUILD-INSTALL-DONE-<status>`. There is
  no cancel: a dpkg killed halfway leaves a half-unpacked package.
  It ends with `killall AirBuild3G` after `uicache`, so the next launch is
  the binary just installed with TLSFix in it, and `killall SpringBoard` only
  when Substrate was just installed — not
  `launchctl stop com.apple.SpringBoard`, which over SSH on iOS 6 answers
  "Socket is not connected" and restarts nothing.
- **Substrate is a runtime dependency of the app, not a nicety, and the only
  armv6 build of it is Legacy-iOS-Kit's.** `ABLTrustAll` hooks
  `SecTrustEvaluate` with `MSHookFunction`, and TLSFix is a Substrate tweak
  (`Depends: mobilesubstrate`). saurik's own debs from 0.9.5101 up are
  armv7/arm64 only; the kit relinks 0.9.7114 as `armv6 arm64` and drops it
  into `/var/root/Media/Cydia/AutoInstall` on every iOS 3/4/5 phone it
  jailbreaks, so a phone jailbroken with the kit already has it. This
  repository ships no third-party binaries: get Substrate from the
  jailbreak or from Cydia, and **leave a working one alone at whatever
  version it is** — replacing it re-patches launchd and wants a respring.
- **Never ship AppSync.** AppSync for
  iOS 4 (`net.angelxwind.appsync40plus` 1.2.2) patches
  `/usr/libexec/installd`, and on the 4.2.1 3G the result is SIGKILLed at
  every launch (`launchctl list` shows `-  -9  com.apple.mobile.installd`).
  `uicache`, `lsd` and SpringBoard's own startup
  (`-[SBPlatformController postCurrentConfiguration]` →
  `MobileInstallationSetDeviceCapabilities`) all wait on installd
  synchronously, so the next install hangs in `postinst`'s `uicache` and the
  phone's watchdog kills SpringBoard every 120 s — indistinguishable in the
  log from a slow dpkg. Nothing here needs AppSync: every app is a deb signed
  with `ldid`. The cure is the stock `installd` out of the 8C148 root
  filesystem (`Legacy-iOS-Kit/*_CustomHJ.ipsw` mounts with `hdiutil`).
  `launchctl list | grep installd` is how you tell: a signal in the status
  column means this, not a slow dpkg. `patcyh` on such a phone is the kit's
  bootstrap, not apt: it is an iOS 8.3+ tweak (`Depends: firmware (>= 8.3)`)
  the kit only strips on its ramdisk path; it loads into `lsd` on 4.2.1 and
  was not the cause.

## Code conventions

- Manual retain/release, not ARC — `libarclite` is gone from modern Xcode, so
  ARC cannot target 4.0 at all.
- **Certificates are validated, and the override is off by default.** TLS 1.2
  is TLSFix (a CFNetwork Substrate tweak); stock iOS 4 SecureTransport only
  speaks TLS 1.0. TLSFix then evaluates the chain with `SecTrustEvaluate`
  before the `NSURLConnection` server-trust challenge, and a 2010 trust store
  cannot always build a path a 2026 server expects. `ABLTrustAll.m` can force
  that result — but only while Settings → Trust Any Certificate is on, and it
  reads the flag per call so turning it off takes effect on the next request.
  **Do not make it unconditional again.** The request carries the owner's API
  key as a bearer token; trusting any certificate means anyone who can answer
  for that address can read it. The same flag gates
  `-canAuthenticateAgainstProtectionSpace:` in `ABLChatClient`, so with it off
  Foundation handles the challenge the ordinary way.
- **The app runs as mobile; one small setuid binary beside it is the only
  thing that is ever root.** `airbuildhelper` (`src/helper/`, installed
  `root:wheel` `4755` by `Packaging/postinst`) raises its own uid on the first
  two lines of `main()` and then does exactly one thing — `run` a command,
  `install` a staged file, `prepare` `/var/airbuild`, `stash`/`unstash` a
  path — before exiting. Everything privileged goes through `ABLPrivileged.h`
  and nothing else does: `Execute`, `EditFile`, `PatchFile`, `CheckBuild`,
  every `dpkg` in the installer, the stash, and deleting a project whose build
  tree root owns. It used to be the app itself that was `4755`, behind a 0755
  launch script because SpringBoard SIGKILLs a setuid Mach-O; that put UIKit,
  the photo picker, an HTTPS client talking to a remote endpoint and 60 KB of
  model-authored JSON in one uid-0 process. Do not put the setuid bit back on
  the app, and do not add a second privileged path around the helper.
  `ABLHelperIsAvailable()` is NO on the host, where every one of these falls
  back to running unprivileged, which is what the host tests want.
- **`run` is an unrestricted root shell, and that is the feature.** Any process
  running as mobile can reach root through the helper — as it could through the
  4755 app binary this replaces, on a phone whose owner has an SSH root login.
  It cannot be narrowed without taking the model's shell away, so everything
  around it is narrow instead: `prepare` refuses any path but `ABLDefaultRoot`,
  `install` is a copy and takes no shell fragment, and the helper checks that
  `setuid(0)` actually worked rather than running as mobile and failing every
  command with a permission error that reads like the command being wrong.
- **`/var/airbuild` stays root's; `projects/` and `staging/` are the app's, and
  `ABLProjectStore prepare` is what keeps it that way.** Projects and
  transcripts are then written by the app as itself, with no privilege
  involved at all. The root itself must not be app-writable: it holds
  `bootstrap/`, the payload archives the installer hands to `dpkg` as root, and
  a root-owned directory inside a writable one is not protected — the *entry*
  can be renamed and replaced. That is also why the readiness stamp is written
  through the helper on a phone and directly only on the host. `staging/` is
  0700 and is where `EditFile` puts a file for the helper's `install` to pick
  up; it is not `/tmp`, because a root process should not read an input from a
  world-writable directory at a name that is a pid. A project made while the
  app was still root is adopted on the way past; its `project/` tree is left
  alone, because that is a build directory and rewriting its ownership at every
  launch is minutes of a 3G.
- One `dpkg -i` per group, not per package, and nothing already installed is
  installed again. dpkg reads and rewrites its whole database on every
  invocation; two dozen packages one at a time is two dozen full database
  passes and several minutes on a 3G. `ABLInstalledPackages` reads
  `/var/lib/dpkg/status` once and drops anything already present at the pinned
  version, which is what makes a second run of Environment finish immediately
  instead of reinstalling the toolchain over itself.
- **Four tools, defined once in `ABLTools.h`**: `Execute` (a root shell in the
  project directory), `EditFile` (write a file whole, creating it), `PatchFile`
  (replace an exact stretch of text) and `CheckBuild` (`make`, with
  `/etc/profile.d/airbuild.sh` sourced, returning the last 8 KB). The schema is
  a macro so `ABLChatClient` can carry the wire format without linking the
  implementation, which pulls in the whole privileged path — one source of
  truth, and the host tests stay small. Editing used to be `exec`'s problem,
  which meant every change to a file was a heredoc the model had to escape
  correctly on the first try inside a 16-round turn. `exec` is still accepted
  as a name for `Execute`: transcripts on disk are full of it, and they are
  replayed to the model as history.
- Tool-call rounds loop automatically: the model calls a tool, the app runs it,
  feeds the result back, and continues until the model stops, the user taps
  Stop, or the round limit. Thinking tokens are shown in the transcript, not
  stripped.
- **A new project is seeded from the bundled template, and its tree goes into
  the system prompt.** `ABLTemplate.m` copies
  `skills/airbuild-iphone-3g/template` into `project/` and resolves
  `__NAME__`/`__BUNDLE__`/`__SCHEME__` in one pass over every file, so the
  model starts from a tree that compiles rather than spending its first turn
  writing a Makefile. `ABLRepoDigest.m` then quotes that tree into the prompt
  (32 KB, build output and binaries skipped), which is cheaper than the four
  rounds of `ls -R` and `cat` it replaces. Both happen off the main thread with
  a progress indicator in the top-right slot, because the list is already back
  on screen while they run.
- Nothing that can block runs on the main thread. Each request is an
  `ABLChatStream` on a thread of its own — connecting, decoding the event
  stream and splitting the reply all happen there — and every tool call runs on
  a background thread too. Only finished tokens cross to the main thread, via
  `performSelectorOnMainThread:` in `NSRunLoopCommonModes` so the stream keeps
  arriving while the transcript is being scrolled.
- Work in flight is abandoned by identity, never by tearing it down: the
  client bumps a generation on every send and cancel, the controller bumps a
  turn. A stream whose generation is stale stops itself, and a shell command
  that has already started finishes into a turn nobody is listening to. Do not
  reintroduce a "stopped" flag — a boolean cannot tell one turn from the next,
  and the bug that produces is stale tool output appearing in a later
  conversation.
- The transcript refreshes on an interval (`ABLTranscriptRefreshInterval`),
  not once per token. A 3G cannot remeasure and rescroll a table at token
  rate. Rows hold a mutable content string so a streamed reply grows in place.
- `<think>` and `<tool_call>` markup is resolved by `ABLChatStream` while the
  reply is still a stream, so it never reaches the transcript and is never
  echoed back to the model as assistant content next to the structured call.
  Its splitting is covered by `make test` at every chunk boundary; that test
  exists because the failures here are all "the tag landed across two
  packets".
- `tools/ablshot.m`-style CLI helpers must link UIKit: a Foundation-only
  armv6 binary from this toolchain is SIGKILLed at launch on the 3G.
- iOS 4 has no `NSJSONSerialization`; keep JSON parsing bounded in
  `ABLJSONParser` and cover valid, malformed, Unicode, and nesting boundaries
  with `make test`.
- Projects live in `/var/airbuild/projects/<uuid>/` — `manifest.plist`, an
  append-only `conversation/round_<n>.plist` per round, and `project/`, which
  is the working directory of every tool call. A round is one user message plus
  everything the assistant produced until it stopped. It is written when it
  opens, after each tool round, and at every close, always by index, so
  closing one twice is harmless and a kill mid-reply costs only the tokens in
  flight. Never rewrite the whole transcript to record one token.
- Project plists are written **binary**, not XML: an XML plist stores dates to
  the whole second, which cannot order two projects touched in the same one,
  and binary parses faster on a 3G. `ABLWritePropertyList` in `ABLProject.m` is
  the only writer; reads use `NSPropertyListMutableContainersAndLeaves` so a
  reopened reply is still appendable.
- The build environment is data, not code: `Packaging/payload.lock` pins every
  package by URL and sha256, and `tools/fetch_payload.py` generates the install
  plan the app walks (`manifest.plist`, phases `stash` → `install` → `ready`).
  `apt-get` is never involved — `iphone-gcc`, `libgcc`, `csu` and `odcctools`
  are present as *files* on `apt.saurik.com` but absent from its `Packages`
  index, so only exact filenames work. `--refresh` reads each candidate's own
  Mach-O headers and rejects anything an armv6 3G cannot execute; do not pin a
  package by version number alone.
- **The lock's group column is install order and target membership, and both
  matter.** `odcctools` and `cctools` declare `Depends: openssl, uuid`; with
  `uuid` in the wrong group the linker installs and then dies with
  `Library not loaded: /usr/lib/libuuid.16.dylib`. Both live in `core`,
  which every target ships.
- **Every package the payload installs is marked `hold`, and that is why Cydia
  stops offering to break the phone.** Cydia carries a newer `ldid`
  (`1:1.2.1`, which the iOS 6 payload pins on purpose — see below) and a newer `network-cmds`, and taking
  the first one alone ends the project: nothing can be signed, and an unsigned
  binary is SIGKILLed at launch. `hold` is the flag Cydia's own "Ignore
  Upgrades" sets, so held packages leave its badge and its upgrade list. Our
  own installs are unaffected — `dpkg -i --force-all` includes `--force-hold`.
  Do **not** solve this by repacking the debs with a fake version like
  `999.999.999`: `ABLInstalledPackages` compares the installed version against
  the pinned one to decide what to skip, and a phone where every package
  claims `999.999.999` can no longer tell the 2008 `iphone-gcc` from the 2009
  one — which is the exact trap the pin exists to avoid.
- **`apt-get -s dist-upgrade` reporting nothing is not proof there is nothing.**
  One unmet dependency anywhere makes apt abandon the whole calculation, so it
  answered "0 upgradable" on a phone Cydia was correctly badging. `git` was
  installed without `expat`, which is what broke the tree; `expat` is in the
  lock now. Check `apt-cache policy` per package, not the resolver's summary.
- **Nothing rebases the system.** The `base` group is pinned so a wiped phone
  can be rebuilt, but neither payload ships it: force-reinstalling a working
  jailbreak's `dpkg`, `apt7`, `openssh` and `pam` with saurik's newest builds
  is the blind upgrade the skill warns against, and on 4.2.1 it replaces
  binaries that then reference symbols the OS does not have.
- **The on-device toolchain is pinned to `iphone-gcc 4.2-20080604-1-8`, and the
  newer `4.2-20090304-1-9` must not be used.** The 2009 build carries Apple's
  precompiled-header arena — `static char pch_address_space[1024*1024*1024]` in
  `gcc/config/host-darwin.c` — as a gigabyte of `__DATA,__bss`, which puts
  `__common` above `0x40000000`. `VM_MAX_ADDRESS` on an armv6 iPhone is
  `0x30000000`, so every `cc1*` backend takes SIGBUS before `main` and every
  compile fails as `gcc: Internal error: Bus error (program cc1obj)`. Probes
  pin the boundary exactly: the same binary runs with a 512 MB array and
  bus-errors with a 768 MB one. The 2008 build has no arena at all and every
  segment sits below `0x600000`, so it runs as shipped, unsigned and unpatched.
  Both are Apple build 5555, so nothing is lost by using the older one.
- **The SDK is rewritten before it ships, by `make payload`, and neither change
  is optional.** `tools/sanitize_sdk.py` removes every block declaration from
  the headers, and then every declaration that uses a typedef it removed —
  `NSComparator`, `dispatch_block_t` — walking again until nothing new goes: blocks arrived in Apple GCC build 5646 and this compiler is
  5555, and the 4.1 headers declare them unguarded, so a plain
  `#import <UIKit/UIKit.h>` cannot parse. It also empties `NS_FORMAT_FUNCTION`,
  which GCC 4.2 rejects with an error rather than a warning. What is left is
  the iOS 3-era API surface, which iOS 4 runs. `tools/mkdevstubs.py` writes the
  libraries, because **there is nothing on the phone to link against**: since
  iOS 3.1 every system library lives in the dyld shared cache and
  `/System/Library/Frameworks/Foundation.framework` holds only an `Info.plist`.
  Each stub carries the real install name and the names of every symbol the
  real library exports, aliased to one empty byte — enough for `ld` to resolve
  a reference and record which library it came from, and dyld binds it to the
  shared cache at launch. 15 MB (1.5 MB in the deb), against 163 MB for the
  SDK's own copies.
- **Only the iOS 4 payload gets the sanitised headers, armv6 stubs and
  `ldid 610-5`; the iOS 6 one ships the headers as Apple wrote them, armv7
  stubs and `ldid 1:1.2.1`.** clang has blocks, and the sanitiser is worse
  than useless to it: it drops `typedef … (^NSComparator)` and
  `dispatch_block_t` but not the methods that take them, so Foundation itself
  stopped parsing — `NSSortDescriptor.h: expected a type`, eighteen errors,
  "Unable to compile the test app" on a 3GS. `ldid 610` asserts
  (`arch != NULL`) on any thin armv7 Mach-O, which is every binary clang
  produces; `1:1.2.1` is an armv6 build declaring iOS 2.0 — not the iOS 5
  armv7 build Cydia's listing suggests — and signs both. `WANTED` in
  `tools/fetch_payload.py` pins each by version so `--refresh` cannot swap
  them; the 3G stays on 610 because that is what has been verified there.
  The clang target also gets `gcc`/`cc`/`g++`/`c++` links to clang, because
  the template's Makefile calls `gcc`.
- **The stubs must carry symbols, and `-undefined dynamic_lookup` must not come
  back.** Empty stubs are 3.8 MB rather than 15 MB, but nothing resolves
  against them, so no `LC_LOAD_DYLIB` is recorded, a link that forgot
  `-framework UIKit` *succeeds*, and the app dies at launch with
  `Symbol not found: _OBJC_CLASS_$_NSAutoreleasePool, Expected in: dynamic
  lookup`. That is the crash the model on the phone kept hitting, and it also
  hid two missing flags: `IOS_LDFLAGS` needs `-lobjc` and
  `-framework CoreFoundation`, because this driver adds neither when its input
  is a `.o`. Symbols exported by the real library whose names begin with
  `$ld$` are linker directives, not symbols, and are skipped.
- **The three packages are reproducible, and a fresh clone is how you find out
  they are not.** `SOURCE_DATE_EPOCH` comes from the tree's last commit and the
  debroot is stamped whole before packing, because `dpkg-deb` writes the time
  it ran into the ar members and only *clamps* file mtimes — a file already
  older than the epoch keeps its own, and two checkouts have different ones.
  Everything inside was already deterministic (`-no_uuid`, normalised tar
  members, `gzip mtime=0`); the deb around it was not, which is exactly what
  building the same commit twice in two directories showed and nothing else
  would have.
- **The SDK need not be Apple's.** `tools/sdk_from_payload.py <bootstrap4.deb>
  <dir>` recovers `iPhoneOS4.1.sdk` from any shipped bootstrap4 package: the
  sanitised headers with the two block typedefs put back (host clang has
  blocks), the link stubs relabelled armv7 so `mkstubs.py` reads them, and
  `mkstubs.py` adds the `dyld_stub_binder` a stub libSystem lacks. The
  reference Mac lost the real SDK this way and rebuilt app and payloads from
  the installer's own deb; the price is that anything the sanitiser removed
  cannot be compiled against on the host either.
- **`build/payload/<target>/sdk.tar.gz` is cached, and the cache is keyed on
  `tools/sanitize_sdk.py`, `tools/mkdevstubs.py` and `tools/fetch_payload.py`.** It is the output of
  those two scripts, so editing either has to reach the phone. Before that
  check existed, changing the stubs and running `make package` shipped a
  payload whose libraries were a release behind the `IOS_LDFLAGS` in the same
  manifest, and every on-device link failed with undefined `_objc_msgSend`.
- **`-isysroot` hides the compiler's own headers.** It prefixes the built-in
  include path too, and the SDK has no `usr/lib/gcc`, so `stdarg.h` disappears
  and every Foundation include fails. `/etc/profile.d/airbuild.sh` sets `CPATH`
  to put it back, and exports `IOS_CFLAGS`/`IOS_LDFLAGS` so nothing on the
  phone has to remember any of this.
- **`iphone-gcc` provides no `gcc`.** It installs only the
  `arm-apple-darwin9-*` names, so the manifest's `cc-links` step symlinks
  `gcc`, `cc`, `g++`, `c++` and `cpp` next to them. Without it the toolchain
  installs and every Makefile still fails with `gcc: command not found`.
- **Neither perl nor Theos is shipped, and neither should come back.** Logos
  (`.x`/`.xm`) is a perl program, the only perl in either repository is armv7
  declaring iOS 4.3, and Theos without Logos is a build system for a language
  this project does not use. An app here is `.m` → `gcc` → `ld` → `ldid`, and
  the template in `Resources/skills/airbuild-iphone-3g/template/` is that in
  30 lines of Makefile.
- **The remembered conversation is in `NSUserDefaults`, and reopening it at
  launch is not a convenience.** iOS 4 has no background execution: a call, the
  home button or a low-memory kill ends the process outright, and on a 128 MB
  phone that happens often. `ABLDefaultsOpenProjectKey` is written by the
  transcript as it appears and cleared by the project list as *it* appears, so
  going back to the list means "nothing is open" and being killed does not.
- **`CFFIXED_USER_HOME` is gone with the setuid bit.** It was there because
  root's home is `/var/root`, where a phone keeps neither its photo library nor
  its preferences — Choose Photo opened on an empty library and created
  `/var/root/Media` to hold nothing. Running as mobile, the home directory is
  already the right one. `Packaging/postinst` carries the old settings across
  from root's home once, because mobile cannot even read it.
- **An app that does nothing when tapped, and leaves no crash report, is a
  stranded `launchd` job, not a crash.** `launchctl list` shows
  `UIKitApplication:<bundle id>[0x….]` with no pid; the bootstrap name is still
  taken, so every launch exits before it draws anything. `launchctl remove` on
  that label is the cure, and `Packaging/postinst` now does it on every
  install, because reinstalling is what a person tries first and it used to
  change nothing. Neither SIGTERM nor SIGKILL produces this — both were tested
  on a throwaway app and both deregister cleanly — so do not go looking for a
  stray `killall`.
- Stashing (`ABLStash`) is the one thing here that can leave a phone unbootable.
  Deny-list matching is by **inode identity**, not spelling, because `/var` is
  a symlink to `/private/var` and `/Applications` and `/usr/share` are already
  symlinks into `/var/stash`. `/usr/lib`, `/usr/bin`, `/System` and every
  top-level directory are refused outright. The copy is compared against the
  original — path set, file count, byte total — before the swap, and the
  original is kept as `<path>.airbuild-old` **for good** — nothing deletes it,
  so the undo works for the life of the device. Stashing is idempotent, and a
  path stashed by the jailbreak years earlier (`/Applications`, `/usr/share`)
  is recognised through its `.lnk` sidecar or its symlink target rather than
  stashed a second time. Copy, never `mv`. `NSDirectoryEnumerator` and `-copyItemAtPath:toPath:` both
  treat a symlink as a symlink, which is what makes a link pointing back up its
  own tree safe; `tests/StashTests.m` plants one to keep that true.
- The iOS 4 `uicache` on the reference custom firmware refuses root. Debian
  maintainer scripts must invoke it through `su mobile -c`.
- **Release *and* nil every ivar in `-dealloc`, in every view controller.**
  `[super dealloc]` tears the view down and UIViewController answers by calling
  `-viewDidUnload` on a controller that is already half gone — which then
  releases the same objects a second time. That double release is what made
  entering Settings and coming back, or opening a project and going back, crash
  after a few navigations; the reports symbolicate to
  `-[… dealloc]` → UIKit → `-[… viewDidUnload]` → `objc_msgSend` on freed
  memory, and there were three in ninety seconds on the reference 3G. Pull a
  crash report with
  `scp root@<device>:/var/mobile/Library/Logs/CrashReporter/… .` and symbolicate
  it against `build/AirBuild3G.app/AirBuild3G` — the load address is
  `0x4000` and `nm -arch armv6 -n` is enough.
- `-viewDidLayoutSubviews` is not an iOS 4 lifecycle method. Frame-based
  layouts must establish their geometry during load/appearance using methods
  actually present in the 4.1 SDK.
- **`detailTextLabel` is never laid out on the reference 4.2.1 3G, in any
  cell style.** The label is non-nil and carries the text (probed from
  inside the app), and the row still draws as if it were empty — the title
  sits centred, the way a Default cell's does — while a plain `UILabel`
  added to the same `contentView` draws. The Environment page's step
  statuses and the project list's subtitles were invisible for months this
  way. `ABLDetailCell` owns both labels and lays them out itself; every row
  with a subtitle or a right-hand value uses it, and nothing touches
  `detailTextLabel`.
- The UI is the iOS 4 idiom, not a modern one restyled: pinstriped grouped
  tables for forms and detail pages (`UITableViewStyleGrouped`), label +
  inline text field rows, actions as navigation bar buttons (blue
  `UIBarButtonItemStyleDone` for the primary one, system items like Refresh),
  a spinner in the bar while loading, `UIAlertView` for errors, disclosure
  rows that push a detail controller, and grey section footers for help text.
  Do not draw flat white pages, big titles, or full-width buttons. The icon
  is derived from AirBuild's `AppIcon.icon` (glyph copied to
  `tools/AirBuildGlyph.svg`) and **pre-rendered** with rounded corners and
  gloss plus `UIPrerenderedIcon` — SpringBoard on the 4.2.1 3G with custom
  firmware leaves third-party icons square otherwise. `Default.png` is the
  empty chrome, not a splash. Regenerate artwork with `make artwork`
  (needs `rsvg-convert` from Homebrew `librsvg`).
- The only real verification of this UI is a jailbroken 3G/3GS over SSH:
  `scp` the deb, `dpkg -i`, `su mobile -c uicache`, `uiopen ab://`.
  `tools/ablshot.m` is a tiny `UIGetScreenImage` CLI; build it armv6 with the
  same compile/relabel/link/patch_minos/ldid steps as the app and drop it in
  `/usr/bin/ablshot` on the device. An all-black capture means the screen is
  locked — `uiopen` the app to wake it. Keep captures in `build/verification/`.
- Tabs for indentation, iOS 4.0-era UIKit only. Anything newer than 4.0 will
  compile against these headers but is a runtime crash on device; check the
  availability comment style in `src/HelloAppDelegate.m` when using an API
  that is 4.0-specific.
- After changing anything in `tools/` or `LDFLAGS`, run `make verify` — it
  catches the regressions that silently produce an unloadable binary
  (`LC_MAIN` instead of `LC_UNIXTHREAD`, a wrong deployment target,
  `movw`/`movt` in the armv6 slice, and an IMP without its Thumb bit).
