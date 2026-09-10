# AirBuild layout and iOS 4 rules

Mac repo (this is the source of the app that is already on the phone):

```
src/                  MRR Objective-C, iOS 4.0 idioms
  main.m              UIApplicationMain; the app runs as mobile, never root
  helper/             airbuildhelper, the one setuid binary beside the app
  HelloAppDelegate.*  window; probes -setRootViewController:
  ABLChatViewController.*  transcript + input bar + tool loop
  ABLChatClient.*     streaming /chat/completions, reply splitter
  ABLSettingsViewController.*  grouped table, base URL/key/model
  ABLJSONParser.*     no NSJSONSerialization on iOS 4
  ABLConfig.h         compile-time defaults (overridable in Settings)
tests/                host-side tests, all runnable without a device
Packaging/            Debian control, postinst/postrm, payload.lock
Resources/            Info.plist, icons, Default.png, bundled skills/
tools/
  mkstubs.py          legacy SDK dylibs → .tbd the modern ld accepts
  patch_minos.py      LC_VERSION_MIN_IPHONEOS 5.0 → 4.0
  relabel_arch.py     flip a thin Mach-O between armv6 and armv7
  mkassets.py         icon + Default.png
  ablshot.m           UIGetScreenImage CLI (must link UIKit)
build/sdkshim/        generated stubs (`make stubs`)
```

Indentation is tabs. Bundle id `com.apple.airbuild.oss`, URL scheme `ab://`, `MinimumOSVersion` 4.0, iPhone-only, `UIPrerenderedIcon`.

## Code rules that apply to anything you compile for this phone

- Manual retain/release. `libarclite` is gone; ARC cannot target 4.0.
- iOS 4.0 UIKit only. Newer APIs compile against these headers and crash on the 3G. Probe 4.0-only selectors (`HelloAppDelegate` and `-setRootViewController:`).
- `-viewDidLayoutSubviews` does not exist. Set frames during load/appearance.
- iOS 4 idiom: grouped tables for forms, label + inline field rows, nav-bar buttons (blue `UIBarButtonItemStyleDone` for the primary action), spinner in the bar while loading, `UIAlertView` for errors, disclosure rows that push, grey section footers for help. No flat white pages, big titles, or full-width buttons.
- Nothing that can block runs on the main thread. AirBuild runs each request on its own thread and every tool call on a background thread; only finished tokens cross to the main thread via `performSelectorOnMainThread:` in `NSRunLoopCommonModes`.
- Abandon in-flight work by identity (generation / turn), never by a boolean "stopped" flag. A stale tool result must not land in a later conversation.
- `<think>` and `<tool_call>` markup is split out of the stream in `ABLChatClient` so it never reaches the transcript and is never echoed back as assistant content next to a structured call.
- iOS 4 has no `NSJSONSerialization`. Keep JSON in `ABLJSONParser` (or an equivalent small parser).
- CLI helpers in the `ablshot.m` style must link UIKit. A Foundation-only armv6 binary from a modern toolchain is SIGKILLed at launch on the 3G.

## Tool contract (what you have on the phone)

Four functions: `Execute` (`command`), `EditFile` (`path`, `content`), `PatchFile` (`path`, `old`, `new`, `replace_all`) and `CheckBuild` (`target`). `Execute` returns combined stdout+stderr with a 64 KB cap; `CheckBuild` returns the last 8 KB of a build. 16 rounds per turn. Commands run as root — the app itself runs as `mobile` and hands them to a setuid helper. Output that is not UTF-8 is decoded as ISO Latin-1.

Inference defaults (Settings override): base URL `https://api.anthropic.com/v1`, model `claude-opus-5`. The endpoint and the key are the owner's — nothing is pinned by a server. Last 20 transcript messages, `stream: true`, `tool_choice: auto`; no `max_tokens` is sent.
