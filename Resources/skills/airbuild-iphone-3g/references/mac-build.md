# Mac build (Xcode 27 → iOS 4.0 fat binary)

This path exists because Xcode 27's linker blocks a 4.0 / armv6 target. The compiler is fine: Clang still emits armv6/armv7 and accepts `-mios-version-min=4.0`. **Do not use this Makefile on the phone.** The phone has a real armv6 assembler and needs none of the workarounds below; build there with the template in `template/`.

Requires the iOS 4.1 SDK (default `~/theos/sdks/iPhoneOS4.1.sdk`, override `LEGACY_SDK=`) and `ldid` (`brew install ldid`).

```sh
make            # build/AirBuild3G.app, and airbuildhelper beside it
make verify     # arch + LC_VERSION_MIN_IPHONEOS + LC_UNIXTHREAD + armv6 ISA + Thumb bit
make test       # JSON parser, reply splitting, project store, stash, tools
make e2e        # real conversation; needs network. E2E_ARGS="https://host key model"
make e2e-device # same client, armv6, copy build/ablchat to the phone
make deb        # Cydia package
make ipa
make clean      # keeps generated SDK stubs
make distclean
```

After changing `tools/` or `LDFLAGS`, run `make verify`.

## The three linker blocks

| Blocker | Workaround |
|---|---|
| Legacy SDK dylibs predate `LC_VERSION_MIN_IPHONEOS`, so `ld` reports platform `unknown` | `tools/mkstubs.py` rewrites them as `.tbd` declaring `armv7-ios`. Link with `-F`/`-L` against `build/sdkshim`. `-isysroot` still points at the real SDK for headers. Adding a framework means adding it to `FRAMEWORKS`. |
| `ld` refuses any iOS deployment target below 4.3 | Compile at 4.0, link at 5.0, `tools/patch_minos.py` stamps 4.0. |
| `ld` refuses `-arch armv6` | Compile real armv6 objects, relabel cpusubtype to armv7 for the link, relabel the linked slice back (`tools/relabel_arch.py`), `lipo` with the armv7 slice. |

Keep `-Wl,-no_pie`. The armv6 relabel is safe only while `ld`'s symbol stubs stay plain ARM `ldr`/`add`; iOS also had no ASLR before 4.3. On ld-27037.1 the stubs are the same either way, so `make verify` asserts the property directly — it fails on any `movw`/`movt` in the armv6 slice.

Keep explicit `-lobjc` and `-framework CoreFoundation`. The clang driver does not auto-link the ObjC runtime when given only `.o` inputs; `_OBJC_CLASS_$_NSObject` and `___CFConstantStringClassReference` live in CoreFoundation in this SDK.

Never link against the legacy SDK's dylibs.

## Mach-O shape `make verify` checks

- `LC_UNIXTHREAD`, not `LC_MAIN`. `LC_MAIN` arrived in iOS 6 with `LC_REQ_DYLD`; iOS 4 dyld refuses it. Linking at 5.0 keeps `LC_UNIXTHREAD`.
- `LC_DYLD_INFO_ONLY`, not chained fixups. 32-bit ARM gets classic bind opcodes.
- `LC_FUNCTION_STARTS` / `LC_DATA_IN_CODE` postdate iOS 4 but lack `LC_REQ_DYLD`; dyld ignores them.

## `make deb` pitfall

`make deb` can reuse an already-built app bundle and skip recompiling even when `src/*.m` are dirty. Force a rebuild of the binary before packaging if sources changed.

## Verification

There is no desktop emulator worth using for this. `make verify` and `make test` are the host-side checks; everything else is the 3G itself. Guard 4.0-only selectors with `respondsToSelector:` rather than removing them.
