#!/usr/bin/env python3
"""Insert DER/PEM certificates into an iOS 4 TrustStore.sqlite3.

Table tsettings(sha1, subj, tset, data). subj is the canonical uppercase
subject Name, not the certificate's raw subject bytes. See
references/certificates.md.

Example:
  python3 truststore_insert.py TrustStore.sqlite3 certs/*.cer
  # then copy the sqlite onto the phone as described in certificates.md
"""
import argparse
import hashlib
import sqlite3
import subprocess
import sys
from pathlib import Path

TSET = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    b'<plist version="1.0">\n'
    b'<array/>\n'
    b'</plist>\n'
)


def read_len(buf, i):
    n = buf[i]
    i += 1
    if n & 0x80:
        c = n & 0x7F
        n = int.from_bytes(buf[i:i + c], "big")
        i += c
    return n, i


def take_tlv(buf, i):
    ln, j = read_len(buf, i + 1)
    return buf[i:j + ln], j + ln


def norm_name(body):
    out = bytearray()
    i = 0
    while i < len(body):
        tlv, nxt = take_tlv(body, i)
        tag = tlv[0]
        if tag & 0x20:
            ln, hdr = read_len(tlv, 1)
            inner = norm_name(tlv[hdr:])
            if len(inner) < 0x80:
                out += bytes([tag, len(inner)]) + inner
            else:
                out += tlv
        elif tag == 0x13:  # PrintableString
            ln, hdr = read_len(tlv, 1)
            val = tlv[hdr:].decode("ascii", errors="replace").upper().encode("ascii")
            out += bytes([tag, len(val)]) + val
        else:
            out += tlv
        i = nxt
    return bytes(out)


def subject_body(cert):
    # TBSCertificate: [version], serial, signature, issuer, validity, subject.
    _, i = read_len(cert, 1)
    tbs, _ = take_tlv(cert, i)
    _, p = read_len(tbs, 1)
    if tbs[p] == 0xA0:
        _, p = take_tlv(tbs, p)
    for _ in range(4):
        _, p = take_tlv(tbs, p)
    subj, _ = take_tlv(tbs, p)
    ln, k = read_len(subj, 1)
    return norm_name(subj[k:k + ln])


def to_der(path):
    data = path.read_bytes()
    if data[:1] == b"\x30":
        r = subprocess.run(
            ["openssl", "x509", "-inform", "der", "-in", str(path), "-outform", "der"],
            capture_output=True,
        )
        if r.returncode == 0 and r.stdout:
            return r.stdout
    r = subprocess.run(
        ["openssl", "x509", "-inform", "pem", "-in", str(path), "-outform", "der"],
        capture_output=True,
    )
    return r.stdout if r.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("store", type=Path, help="TrustStore.sqlite3 to mutate")
    parser.add_argument("certs", nargs="+", type=Path, help="PEM/DER/CER files")
    args = parser.parse_args()

    con = sqlite3.connect(str(args.store))
    have = {row[0] for row in con.execute("SELECT sha1 FROM tsettings")}
    added = 0
    for path in args.certs:
        der = to_der(path)
        if not der:
            print("skip (not a cert)", path, file=sys.stderr)
            continue
        sha1 = hashlib.sha1(der).digest()
        if sha1 in have:
            print("have", path.name, sha1.hex())
            continue
        con.execute(
            "INSERT INTO tsettings(sha1,subj,tset,data) VALUES (?,?,?,?)",
            (sha1, subject_body(der), TSET, der),
        )
        have.add(sha1)
        added += 1
        print("insert", path.name, sha1.hex())
    con.commit()
    total = con.execute("SELECT count(*) FROM tsettings").fetchone()[0]
    con.close()
    print("added", added, "total", total)


if __name__ == "__main__":
    main()
