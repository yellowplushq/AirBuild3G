# Certificates

Three trust stacks. Fixing one never fixes the others.

| Stack | Who uses it | Where | Status on this phone |
|---|---|---|---|
| CFNetwork / UIKit | AirBuild chat client, Safari | `NSURLConnection` / SecureTransport, hooked by TLSFix | TLS 1.2 via TLSFix 1.1. Certificates are validated. `ABLTrustAll.m` can force `SecTrustEvaluate` success, but only while Settings → Trust Any Certificate is on, and it reads the flag per call. Off by default; leave it off. |
| OpenSSL 0.9.8 | `apt-get`, anything linked to `libssl` | `/etc/ssl/certs/ca-certificates.crt` + hash links | Custom `ca-certificates 20260813` installed. Still TLS 1.0 only. |
| iOS Security | Safari, Cydia UI, TLSFix's `SecTrustEvaluate` | `/var/Keychains/TrustStore.sqlite3` | 43 roots; backup `TrustStore.sqlite3.bak`. |

OpenSSL is `0.9.8zg-13` (2015). Even with current CAs it will not speak TLS 1.2, so modern HTTPS hosts still fail at the handshake. That is a protocol limit, not a missing root. `cydia.saurik.com` still offers TLS 1.0 + `AES128-SHA` to iOS 4 — do not install HTTPatch (it downgrades HTTPS to HTTP).

**TLSFix 1.1** (`com.skyglow.tlsfix`) is installed from
https://github.com/nfzerox/TLSFix/releases/download/1.1/com.skyglow.tlsfix_1.1.deb
(gzip, `iphoneos-arm`, armv6 slice min 2.0). It injects into anything linked
with CFNetwork (`tlsfix.plist` `Mode = Any`). The copy on this 3G is the
armv6 slice only (the fat dylib is 6.8 MB). It does not help OpenSSL 0.9.8.

AirBuild talks to whatever OpenAI-compatible endpoint is in Settings
(`ABLChatClient`). TLSFix completes a TLS 1.2 handshake, and then
`SecTrustEvaluate` can still fail on a chain a 2010 trust store cannot build a
path for — today's Let's Encrypt "Root YR" on iOS 4.2.1 is one — and it fails
there, before the `NSURLConnection` challenge is ever reached.

That is what **Settings → Trust Any Certificate** is for. With it on,
`ABLTrustAll.m`'s hook returns `kSecTrustResultUnspecified` and `ABLChatClient`
answers the challenge with the presented trust; with it off, which is the
default, both defer to the ordinary evaluation. The request carries the
owner's API key as a bearer token, so anyone who can answer for that address
can read it — fix the trust store instead (below) and leave the switch off.

## Clock first

If `date` shows year 2000, every 2026 certificate is not-yet-valid. Set the clock ([device.md](device.md)) before touching either store.

## OpenSSL / apt CA bundle

Cydia/Saurik indexes do not ship `ca-certificates`. The installed package was built on the Mac from https://curl.se/ca/cacert.pem (2026-08-13, 121 roots) and copied over.

Layout inside the deb:

- `/etc/ssl/certs/ca-certificates.crt` — concatenated PEM
- `/etc/ssl/certs/<hash>.0` — OpenSSL 0.9.8 subject-hash links (`openssl x509 -hash` on the phone, not a newer OpenSSL)
- `/etc/apt/apt.conf.d/99ca-certificates` — `Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";`

Pack with gzip; the phone's `dpkg` cannot unpack xz:

```sh
dpkg-deb -Zgzip --root-owner-group -b pkg ca-certificates_YYYYMMDD_iphoneos-arm.deb
scp … root@&lt;phone&gt;:/tmp/
ssh … 'dpkg -i /tmp/ca-certificates_YYYYMMDD_iphoneos-arm.deb'
```

This does not fix Cydia's GUI.

## iOS TrustStore

Path: `/var/Keychains/TrustStore.sqlite3` (owner `_securityd` / uid 64, mode 600). Table `tsettings` columns: `sha1`, `subj`, `tset`, `data`.

- `sha1` — SHA-1 of the certificate DER
- `subj` — **canonical uppercase** subject Name DER, not the certificate's raw subject bytes. PrintableString (tag `0x13`) values must be uppercased; other tags copied.
- `tset` — empty plist array:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <array/>
  </plist>
  ```

- `data` — certificate DER

Do not add roots via Safari `.mobileconfig`. On 4.2.1 that often fails with "could not download profile".

Community dump for Cydia on iOS 4.1–7: `http://tlsroot.litten.ca/` (HTTP). DigiCert Global Root G2, ISRG Root X1, and USERTrust RSA were already in this phone's store before the extra 11 (Apple WWDR intermediates + older GlobalSign/GTS) were inserted. Total 43. Cydia's certificate errors were primarily the 2000 clock, not missing DigiCert.

Writer: `scripts/truststore_insert.py`. After writing:

```sh
cp /var/Keychains/TrustStore.sqlite3 /var/Keychains/TrustStore.sqlite3.bak
# replace the sqlite, then:
chown 64:0 /var/Keychains/TrustStore.sqlite3
chmod 600 /var/Keychains/TrustStore.sqlite3
killall -9 securityd
killall -9 Cydia
# optional: drop Cydia's web cache under /var/mobile/Library/...
uiopen cydia://
```
