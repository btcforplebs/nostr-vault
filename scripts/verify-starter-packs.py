#!/usr/bin/env python3
"""Check the bundled starter packs before shipping them.

The onboarding "Discover Accounts" step offers these people by name, so a
wrong npub follows a stranger under a famous name. That shipped once: until
2026-10 only 2 of 15 entries pointed at the person named. Run this after any
edit to starter_packs.json:

    python3 scripts/verify-starter-packs.py           # offline checks only
    python3 scripts/verify-starter-packs.py --online  # also resolve every NIP-05

Offline: the iOS and Android copies are byte-identical, every npub passes its
bech32 checksum, and every entry carries a nip05. Online: each nip05 resolves
to exactly that entry's pubkey. Exits non-zero on any failure.
"""
import json
import pathlib
import ssl
import sys
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS = ROOT / "HavenApp/HavenApp/Resources/starter_packs.json"
ANDROID = ROOT / "NostrVault/app/src/main/res/raw/starter_packs.json"

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _polymod(values):
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if (top >> i) & 1 else 0
    return chk


def npub_to_hex(npub):
    """Strict decode: lowercase, hrp 'npub', valid checksum, 32 bytes."""
    if npub != npub.lower() or not npub.startswith("npub1"):
        return None
    data = npub[len("npub1"):]
    if any(c not in CHARSET for c in data) or len(data) < 7:
        return None
    values = [CHARSET.index(c) for c in data]
    hrp = [ord(c) >> 5 for c in "npub"] + [0] + [ord(c) & 31 for c in "npub"]
    if _polymod(hrp + values) != 1:
        return None
    acc = bits = 0
    out = bytearray()
    for v in values[:-6]:
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
    return out.hex() if len(out) == 32 else None


def resolve_nip05(identifier):
    name, _, domain = identifier.partition("@")
    url = f"https://{domain}/.well-known/nostr.json?name={urllib.parse.quote(name)}"
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()
    req = urllib.request.Request(url, headers={"User-Agent": "nostr-vault-starter-check"})
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
        names = json.load(resp).get("names", {})
    # NIP-05 lookups are case-insensitive in practice; servers vary.
    for key, value in names.items():
        if key.lower() == name.lower():
            return value
    return None


def main():
    online = "--online" in sys.argv
    failures = []

    if IOS.read_bytes() != ANDROID.read_bytes():
        failures.append(f"{IOS.relative_to(ROOT)} and {ANDROID.relative_to(ROOT)} differ")

    packs = json.loads(IOS.read_text())["packs"]
    seen = {}
    count = 0
    for pack in packs:
        for account in pack["accounts"]:
            count += 1
            label = f"{pack['id']}/{account['name']}"
            hex_key = npub_to_hex(account["npub"])
            if hex_key is None:
                failures.append(f"{label}: npub fails its checksum")
                continue
            if hex_key in seen:
                failures.append(f"{label}: same pubkey as {seen[hex_key]}")
            seen[hex_key] = label
            nip05 = account.get("nip05", "")
            if "@" not in nip05:
                failures.append(f"{label}: no nip05 to prove who this is")
                continue
            if online:
                try:
                    resolved = resolve_nip05(nip05)
                except Exception as exc:  # network errors are failures, not passes
                    failures.append(f"{label}: {nip05} lookup failed ({exc})")
                    continue
                if resolved != hex_key:
                    failures.append(f"{label}: {nip05} resolves to {resolved}, entry has {hex_key}")
                else:
                    print(f"ok  {label:24} {nip05}")

    if failures:
        print(f"\n{len(failures)} problem(s) in {count} entries:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)
    print(f"\n{count} entries OK ({'online' if online else 'offline'} checks)")


if __name__ == "__main__":
    main()
