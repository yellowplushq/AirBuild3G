# AirBuild3G

A coding agent that runs on an **iPhone 3G**.

Not a remote control for one somewhere else — the model streams to the phone,
the tool calls run on the phone, and the compiler is on the phone. You
describe an app; GCC 4.2 on a 2008 ARM11 builds it and it appears on the home
screen. The whole loop fits in 128 MB of RAM, because it has to.

Built for **iOS 4.0** on the **iPhone 3G (armv6)** and **iPhone 3GS (armv7)**
with a current Xcode toolchain, which is a thing the current Xcode toolchain
refuses to do in three separate ways. `blog/` has the long version.

**Bring your own key.** Three settings — base URL, API key, model — and
requests go straight from the phone to that endpoint. No server of ours, no
account, no device identity. The wire format is OpenAI's `/chat/completions`,
so the same field points at Anthropic's compatible endpoint (the default),
OpenRouter, or a llama.cpp server on your own Wi-Fi.

**To install it: give [`INSTALL.md`](INSTALL.md) and this repository to a
coding agent.** That is the release. There are no prebuilt packages — an iOS 4
phone's OpenSSL speaks TLS 1.0 and cannot fetch one from anywhere on today's
web.

Jailbroken devices only. Substrate is a runtime dependency; every phone
Legacy-iOS-Kit jailbreaks has it.

## Build

```sh
make            # build/AirBuild3G.app  (armv6 + armv7, plus the setuid helper)
make verify     # architectures and the load commands iOS 4's dyld demands
make test       # JSON parser, reply splitting, project store, stash, tools
make package    # all three .deb packages
make install-device DEVICE=root@<ip>
```

Needs the iOS 4.1 SDK (`~/theos/sdks/iPhoneOS4.1.sdk`, or `LEGACY_SDK=`) and
`brew install dpkg ldid`. Without `ldid` the binary is unsigned and will not
launch.

## Why this needs a workaround

Xcode 27 ships only the iOS 27 SDK, and its linker blocks a 4.0 target three
ways. The compiler is fine — Clang still emits armv6 and still accepts
`-mios-version-min=4.0`.

| Blocker | Workaround |
| --- | --- |
| The iOS 4.1 SDK's dylibs predate `LC_VERSION_MIN_IPHONEOS`, so `ld` sees platform `unknown` and errors | `tools/mkstubs.py` regenerates them as `.tbd` stubs declaring `armv7-ios` |
| `ld: building for iOS with 4.0 minimum deployment target is no longer supported` | Link at 5.0, then `tools/patch_minos.py` stamps the load command back to 4.0 |
| `ld: linking for armv6 is no longer supported` | Compile real armv6, relabel `cpusubtype` to armv7 for the link, relabel back (`tools/relabel_arch.py`) |

Headers still come from the real SDK via `-isysroot`; only the *link* is
redirected. `make verify` then checks the three things that produce a binary
which builds cleanly and cannot be loaded: `LC_VERSION_MIN_IPHONEOS` 4.0,
`LC_UNIXTHREAD` rather than `LC_MAIN`, and the Thumb bit on every method IMP
in the armv7 slice.

`AGENTS.md` is the working agreement: every non-obvious constraint, and why.
Read it before changing anything in `tools/` or `LDFLAGS`.

## Related

The open-source relative of the AirBuild client at
[air.build](https://air.build), with the account, the metering and the device
binding taken out and your own API key in their place.

MIT. Third-party packages it installs on the phone are not ours —
`Packaging/payload.lock` names every one by URL and sha256, and this
repository redistributes none of them.
