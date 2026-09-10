# Package and install

Architecture `iphoneos-arm`. Compression **gzip**. This phone's `dpkg` cannot unpack xz (`dpkg-deb: unable to execute decompressing archive member (xz)`).

```sh
dpkg-deb -Zgzip --root-owner-group -b <root> <out>.deb
```

The Mac `make deb` already passes `-Zgzip -z9`. If a deb from elsewhere is xz, unpack and rebuild:

```sh
mkdir -p /tmp/repack
dpkg-deb -R incoming.deb /tmp/repack || ar x incoming.deb
# if you only have the data/control tarballs, recompress them .gz and ar them
dpkg-deb -Zgzip --root-owner-group -b /tmp/repack /tmp/out.deb
```

## Install sequence that works on this 3G

```sh
dpkg -i com.example_1.0.0_iphoneos-arm.deb
su mobile -c uicache
uiopen example://
```

`dpkg -i` of the same version replaces the previous install in place. `uicache` must run as `mobile`.

From the Mac, the AirBuild package is `build/com.apple.airbuild.oss_1.0.0_iphoneos-arm.deb`:

```sh
sshpass -p alpine scp -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  build/com.apple.airbuild.oss_1.0.0_iphoneos-arm.deb root@&lt;phone&gt;:/tmp/
sshpass -p alpine ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@&lt;phone&gt; 'dpkg -i /tmp/com.apple.airbuild.oss_1.0.0_iphoneos-arm.deb'
```

postinst already runs `su mobile -c uicache`. Then `uiopen ab://`.

An all-black `ablshot` capture means the screen is locked — `uiopen` the app to wake it. Keep captures in `build/verification/` on the Mac.

## Apps that need root: a setuid helper, not a setuid app

SpringBoard runs as `mobile` and SIGKILLs a setuid Mach-O, so an app cannot be
setuid itself. There are two ways around that, and only one of them is worth
copying.

**Do this.** Ship a second, tiny binary in the bundle, `4755 root:wheel`, whose
`main()` starts with `setgid(0); setuid(0);` and then does one thing and exits.
The app stays an ordinary `0755` Mach-O running as `mobile` and spawns the
helper when it needs root. AirBuild's own is
`/Applications/AirBuild3G.app/airbuildhelper`, and everything privileged in
the app — the shell behind Execute, `dpkg`, the stash, writing a file into a
root-owned directory — goes through it.

| File in the `.app` | Mode | Role |
|---|---|---|
| `CFBundleExecutable` | `0755` `root:wheel` | the app, run as `mobile` |
| helper | `4755` `root:wheel` | raises its own uid, does one command |

**Not this.** The older trick — `CFBundleExecutable` is a `/bin/sh` wrapper
that `exec`s a `4755` Mach-O beside it, which then `setuid(0)`s — works, and
Cydia and iFile use it. It also puts UIKit, the network stack and everything
the app parses inside a uid-0 process for the sake of a few operations. Prefer
the helper.

CLI tools that need root can be `4755` under `/usr/bin` with no wrapper at all
— SpringBoard is not launching them.

## control

```
Package: com.example.foo
Name: Foo
Version: 1.0.0
Architecture: iphoneos-arm
Depends: firmware (>= 4.0)
Section: Applications
```

Stock-device install is not possible from this toolchain: it would need a provisioning profile whose certificate chain iOS 4 still trusts, and current Apple developer certificates are not that chain. The ad-hoc `ldid` signature is what this custom-firmware 3G expects.
