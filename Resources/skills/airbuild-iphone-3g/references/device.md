# Device

The reference device is an iPhone 3G (`iPhone1,2`), iOS 4.2.1 custom
firmware, OpenSSH 6.7, 128 MB RAM. Everything below was established on it.
`<phone>` stands for your own device's address on the LAN; the default
jailbreak login is `root` / `alpine`.

## SSH from the Mac

The phone's host key is `ssh-rsa`. Current OpenSSH has that algorithm off by default; re-enable it in `~/.ssh/config` (`Host *`) or `/etc/ssh/ssh_config.d/legacy-rsa.conf`:

```
HostKeyAlgorithms +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
```

Do not enable `ssh-dss` — OpenSSH 10.3 removed it. Password auth (the phone has no key):

```sh
sshpass -p alpine ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<phone>
sshpass -p alpine scp -o PreferredAuthentications=password -o PubkeyAuthentication=no FILE root@<phone>:/tmp/
```

## apt

There is no `apt` binary. Cydia's GUI links `libapt`; the CLI is the `apt7` package ("APT 0.7 Strict").

Installed from `apt.saurik.com`: `berkeleydb`, then `apt7` → `apt-get` / `apt-cache` (`apt 0.7.25.3 for iphoneos-arm`).

```sh
apt-get update
apt-get install <pkg>
```

Dead indexes (e.g. `repo666.ultrasn0w.com`) returning 400 are expected; old lists are used.

Do not run a blind `apt-get upgrade`. Saurik still ships packages for much newer firmware. `com.saurik.patcyh` (Patcyh) was an iOS 8.3+ `installd` leftover (`Depends: firmware >= 8.3`); it was purged and pinned. `uikittools` already has `firmware (<< 8.3) | com.saurik.patcyh`, so iOS 4 does not need it.

If `apt-get -f install` is waiting at `Do you want to continue [Y/n]?` after the lock was cleared: Ctrl-C.

## Clock

A 2008 battery lets the clock fall back to **2000** across reboots. 2026 certificates then fail as not-yet-valid. Check `date` before any TLS work.

```sh
date -u -s 'YYYY-MM-DD HH:MM:SS'    # UTC
```

Set a timezone and turn **automatic time off**, so the phone is not pulled back to 2000. On the reference device that is `Asia/Tokyo`:

- `/var/db/timezone/localtime` → `/usr/share/zoneinfo/Asia/Tokyo`
- `/var/mobile/Library/Preferences/com.apple.preferences.datetime.plist`:
  `timezone = "Tokyo, Japan"`, `timezoneset = true`, `automatic-time = false`
  owner `mobile:mobile`, mode `600`

## Helpers already on the phone

`/usr/bin/ldrestart`, `/usr/bin/sbreload`, `/usr/bin/uiopen`, `/usr/bin/uicache`.
`uicache` on this firmware refuses root: always `su mobile -c uicache`.
