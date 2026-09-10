# TODO

## Done

- **The on-device compiler works.** `iphone-gcc` is pinned to
  `4.2-20080604-1-8`; the 2009 build's 1 GB `pch_address_space` puts `__common`
  above the armv6 `VM_MAX_ADDRESS` of `0x30000000` and every `cc1*` backend
  takes SIGBUS before `main`. No binary patching: the 2008 build runs as
  shipped.
- **The SDK is made compiler-ready at package time.** `tools/sanitize_sdk.py`
  strips block declarations and `NS_FORMAT_FUNCTION`; `tools/mkdevstubs.py`
  writes 15 MB of link stubs (1.5 MB in the deb), because the phone's own
  system libraries are in the dyld shared cache and cannot be linked against.
- **The stubs carry symbols, and `-undefined dynamic_lookup` is gone.** Empty
  stubs were 3.8 MB, but nothing resolved against them, so no `LC_LOAD_DYLIB`
  was recorded and a link that forgot `-framework UIKit` succeeded and then
  died at launch with `Symbol not found … Expected in: dynamic lookup`. That
  was the crash on the phone. It also hid two missing flags: `IOS_LDFLAGS` now
  carries `-lobjc` and `-framework CoreFoundation`.
- **`sdk.tar.gz` is invalidated by the scripts that build it.** It used to be
  cached on existence alone, so a change to the stubs shipped a payload a
  release behind the manifest that linked against it.
- `make hello-device` compiles, links, signs, packages, installs and launches a
  UIKit app on the 3G. Verified on the reference device.
- `make package` builds everything offline from `build/payload/cache`, and all
  three packages are byte-identical to a fresh clone's — verified by cloning to
  /tmp, `git clean -fdx`, building from nothing and comparing sha256.
- Environment installs one `dpkg` call per group and skips packages already at
  the pinned version, so a second run finishes immediately.
- A "Welcome to AirBuild" alert with Go Home when all three phases are green.
- **Settings → Reinstall Everything** runs every step and every package again,
  whatever dpkg reports. `-start` is idempotent by design, which makes it the
  wrong tool for a toolchain that is damaged rather than missing.
- Command output in the transcript is three lines, tinted pale green or pale
  red by exit status, and opens in full on a tap. The three lines are the
  *last* three: that is where the error and the `(exit N)` marker are.
- `Resources/skills/.../scripts/build-app.sh` and `check-toolchain.sh`, both
  verified on the device.
- `make test` — JSON parser, stream splitting, project store, stash, and the
  edit/patch/digest tools all pass.
- The stash is idempotent, recognises paths the jailbreak already stashed, and
  keeps `<path>.airbuild-old` for the life of the device.
- The app holds the idle timer while it is in the foreground.
- **Reinstalling clears a stranded `launchd` job.** A `UIKitApplication` entry
  that outlives its process keeps the bootstrap name, and the app then exits
  at every launch with no crash report — indistinguishable from a crash on
  open. `Packaging/postinst` removes it.
- **Choose Photo sees the phone's photos.** It needed `CFFIXED_USER_HOME` while
  the app was root, whose home is `/var/root` and holds neither the library nor
  the preferences. Running as mobile, the home directory is already the right
  one; `Packaging/postinst` carries the old settings across once.
- **TLSFix ships from its GitHub release**, since it is on no apt repository:
  `com.skyglow.tlsfix` 1.1, pinned by URL and sha256 like everything else.
  Installed, held and armv6 on the reference 3G.
- **perl and Theos are gone.** Logos is a perl program, no perl runs on armv6,
  and Theos without Logos builds nothing this project wants. Apps are plain
  `.m`; the payload lost a package and a 0.76 MB tarball with it.
- **Every pinned package is `hold`ed** by an install step, so Cydia stops
  offering the newer `ldid` (iOS 5 / armv7 — it would end signing on this
  phone) and the newer `network-cmds`. `expat` is in the lock too: `git` was
  installed without it, which left apt's dependency tree broken and made
  `apt-get -s dist-upgrade` answer "nothing to do" on a phone that had two
  pending upgrades.
- **The app is not root any more.** It runs as mobile like any other app; the
  only setuid binary is `airbuildhelper`, `4755` beside it in the bundle, which
  raises its own uid and does one command before exiting. Execute, EditFile,
  PatchFile, CheckBuild, every dpkg in the installer, the stash and deleting a
  project all go through it. Verified on the reference 3G: the process is
  `mobile`, `helper run "" id` from mobile answers `uid=0(root)`, and
  `helper install` writes into a root-owned directory a mobile process cannot
  touch.
- **Push and pop no longer crash.** Every view controller released the same
  ivars in `-dealloc` that its `-viewDidUnload` releases, and `[super dealloc]`
  calls `-viewDidUnload`. Three crash reports in ninety seconds on the device
  symbolicated to exactly that: `-[… dealloc]` → UIKit → `-[… viewDidUnload]`
  → `objc_msgSend` on freed memory. Every one of them now nils what it
  releases.
- **Four tools instead of one.** `Execute`, `EditFile`, `PatchFile` and
  `CheckBuild`, defined once in `ABLTools.h`. Writing a file used to be a
  heredoc the model had to escape correctly on the first try inside a 16-round
  turn. `exec` is still accepted as a name for `Execute`, because reopened
  transcripts are full of it.
- **A new project starts from the template, with its tree in the prompt.** The
  bundled single-view app is copied in and its placeholders resolved when the
  project is made — on a background thread, with a progress indicator where the
  + button is — and `ABLRepoDigest` quotes the working tree into the system
  prompt.
- **The open conversation survives being killed.** iOS 4 has no background
  execution, so leaving AirBuild ends the process; the project on screen is
  remembered in `NSUserDefaults` and reopened at launch.

## Open

- **`lipo` from odcctools traps** on this `libSystem` (`_map_fd`). `file` and
  `otool -h` work.
- The iOS 6 / armv7 payload (clang) has not been run on hardware — there is no
  3GS or iPod touch here to test it on.
- The new tool loop has been exercised on the host (`make test`) and the helper
  on the device, but a full conversation that edits, patches and builds through
  the four tools has not been run on the phone yet.
