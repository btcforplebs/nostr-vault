#!/usr/bin/env python3
"""Writes the mesh copy v2 fixtures (docs/MESH_COPY_V2_CONTRACT.md). Change the rule here first, run
`python3 reference.py`, then make the engine and both apps agree. Every hex value is the sha256 of a label:
no real key, account or device."""
import hashlib, json, math, os

HERE = os.path.dirname(os.path.abspath(__file__))
CHUNK = 4194304
def h(label): return hashlib.sha256(label.encode()).hexdigest()
OWNER = h("owner")
OTHER = h("someone else")
THIRD = h("a third account")

# bech32 (BIP-173), for npubs of the label keys above.
_B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def _polymod(values):
    g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; chk = 1
    for v in values:
        b = chk >> 25; chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5): chk ^= g[i] if ((b >> i) & 1) else 0
    return chk
def _bech32(hrp, data):
    acc, bits, out = 0, 0, []
    for b in data:
        acc = (acc << 8) | b; bits += 8
        while bits >= 5: bits -= 5; out.append((acc >> bits) & 31)
    if bits: out.append((acc << (5 - bits)) & 31)
    hx = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    pm = _polymod(hx + out + [0] * 6) ^ 1
    return hrp + "1" + "".join(_B32[d] for d in out + [(pm >> 5 * (5 - i)) & 31 for i in range(6)])
def npub(hexkey): return _bech32("npub", bytes.fromhex(hexkey))
def zip_key(parts): return hashlib.sha256("\n".join(p["sha256"] for p in parts).encode()).hexdigest()
def part(name, size, tag="a"):
    return {"name": name, "size": size, "sha256": h(f"{name}-{tag}"), "chunk": CHUNK,
            "chunks": [h(f"{name}-{tag}-{i}") for i in range(math.ceil(size / CHUNK))]}
def manifest(parts, **over):
    m = {"v": 2, "id": h("copy-id")[:32], "state": "ready", "error": "", "owner": OWNER, "created_at": 1767000000,
         "progress": {"stores_done": 9, "stores_total": 9, "files_done": 2, "files_total": 2},
         "counts": {"outbox": 3}, "files": {"count": 2, "bytes": sum(p["size"] for p in parts if p["name"] == "media")},
         "settings": "included", "accounts": [npub(OWNER)], "parts": parts, "zip_key": zip_key(parts)}
    m.update(over)
    return m
def write(name, obj):
    with open(os.path.join(HERE, name), "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")

notes, media = part("notes", 9_000_000), part("media", 2 * CHUNK)
good = manifest([notes, media])

def broken(fn):
    m = json.loads(json.dumps(good)); fn(m); return m
manifest_cases = {"owner": OWNER, "cases": [
    {"name": "notes and media", "manifest": good, "expect": {"ok": True}},
    {"name": "notes only (no own uploads)", "manifest": manifest([part("notes", 100)]), "expect": {"ok": True}},
    {"name": "empty media part", "manifest": manifest([notes, part("media", 0)]), "expect": {"ok": True}},
    {"name": "still building", "manifest": broken(lambda m: m.update(state="building")), "expect": {"ok": False, "error": "building"}},
    {"name": "failed on A", "manifest": broken(lambda m: m.update(state="failed", error="no_space")), "expect": {"ok": False, "error": "no_space"}},
    {"name": "wrong owner", "manifest": broken(lambda m: m.update(owner=OTHER, accounts=[npub(OTHER)])), "expect": {"ok": False, "error": "wrong_owner"}},
    {"name": "v3 from a newer A", "manifest": broken(lambda m: m.update(v=3)), "expect": {"ok": False, "error": "unsupported_version"}},
    {"name": "v1", "manifest": broken(lambda m: m.update(v=1)), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "no notes part", "manifest": manifest([media]), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "media before notes", "manifest": manifest([media, notes]), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "a part twice", "manifest": manifest([notes, notes]), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "unknown part", "manifest": manifest([notes, part("extra", 10)]), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "other chunk size", "manifest": broken(lambda m: m["parts"][0].update(chunk=1048576)), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "one chunk short", "manifest": broken(lambda m: m["parts"][0]["chunks"].pop()), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "upper-case hash", "manifest": broken(lambda m: m["parts"][0].update(sha256=m["parts"][0]["sha256"].upper())), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "negative size", "manifest": broken(lambda m: m["parts"][1].update(size=-1)), "expect": {"ok": False, "error": "bad_manifest"}},
    {"name": "zip_key does not match", "manifest": broken(lambda m: m.update(zip_key=h("other"))), "expect": {"ok": False, "error": "bad_manifest"}},
]}
write("manifest-v2-cases.json", manifest_cases)

# §3.4: B takes a copy of its owner's vault, or of a vault whose accounts share one of B's own keys
# ("accounts", hex). Same rule as manifest-v2-cases otherwise.
write("manifest-accounts-cases.json", {"owner": OWNER, "accounts": [OWNER], "cases": [
    {"name": "B's owner's vault", "manifest": good, "expect": {"ok": True}},
    {"name": "another owner's vault that has B's owner as an account", "manifest": broken(lambda m: m.update(owner=OTHER, accounts=[npub(OTHER), npub(OWNER)])), "expect": {"ok": True}},
    {"name": "another owner's vault sharing no account", "manifest": broken(lambda m: m.update(owner=OTHER, accounts=[npub(OTHER), npub(THIRD)])), "expect": {"ok": False, "error": "wrong_owner"}},
    {"name": "another owner, older A without accounts", "manifest": broken(lambda m: (m.update(owner=OTHER), m.pop("accounts"))), "expect": {"ok": False, "error": "wrong_owner"}},
    {"name": "B's owner, older A without accounts", "manifest": broken(lambda m: m.pop("accounts")), "expect": {"ok": True}},
    {"name": "an account that is hex, not an npub", "manifest": broken(lambda m: m.update(accounts=[OWNER])), "expect": {"ok": False, "error": "bad_manifest"}},
]})

rebuilt = manifest([part("notes", 9_000_000, "b"), media])
state = lambda done, failures=None, key=None: {"v": 1, "id": good["id"], "zip_key": key or good["zip_key"], "done": done, "failures": failures or {}}
write("chunk-state-cases.json", {"cases": [
    {"name": "fresh: no state", "manifest": good, "state": None,
     "expect": {"restart": False, "need": {"notes": [0, 1, 2], "media": [0, 1]}}},
    {"name": "half done", "manifest": good, "state": state({"notes": [0, 2], "media": [1]}),
     "expect": {"restart": False, "need": {"notes": [1], "media": [0]}}},
    {"name": "everything done", "manifest": good, "state": state({"notes": [0, 1, 2], "media": [0, 1]}),
     "expect": {"restart": False, "need": {"notes": [], "media": []}}},
    {"name": "a rebuilt zip starts over", "manifest": rebuilt, "state": state({"notes": [0, 1, 2], "media": [0, 1]}),
     "expect": {"restart": True, "need": {"notes": [0, 1, 2], "media": [0, 1]}}},
    {"name": "done indexes outside the part are ignored", "manifest": good, "state": state({"notes": [0, 1, 2, 7], "media": [-1]}),
     "expect": {"restart": False, "need": {"notes": [], "media": [0, 1]}}},
], "failures": [
    {"name": "first bad chunk is fetched again", "before": 0, "expect": {"failures": 1, "stop": False}},
    {"name": "second bad chunk is fetched again", "before": 1, "expect": {"failures": 2, "stop": False}},
    {"name": "third bad chunk stops the copy", "before": 2, "expect": {"failures": 3, "stop": True, "error": "hash_mismatch"}},
]})

write("progress-v2-lines.json", {"cases": [
    {"line": "COPY stage=building part=- bytes=0/0 items=3/9 source=mesh", "expect": {"stage": "building", "part": "-", "bytes": [0, 0], "items": [3, 9], "source": "mesh", "error": ""}},
    {"line": "COPY stage=fetching part=notes bytes=4194304/9000000 items=1/3 source=mesh", "expect": {"stage": "fetching", "part": "notes", "bytes": [4194304, 9000000], "items": [1, 3], "source": "mesh", "error": ""}},
    {"line": "COPY stage=restoring part=media bytes=8388608/8388608 items=2/2 source=mesh", "expect": {"stage": "restoring", "part": "media", "bytes": [8388608, 8388608], "items": [2, 2], "source": "mesh", "error": ""}},
    {"line": "COPY stage=relays part=- bytes=0/0 items=0/0 source=relays", "expect": {"stage": "relays", "part": "-", "bytes": [0, 0], "items": [0, 0], "source": "relays", "error": ""}},
    {"line": "COPY stage=done part=- bytes=0/0 items=21003/21003 source=mesh", "expect": {"stage": "done", "part": "-", "bytes": [0, 0], "items": [21003, 21003], "source": "mesh", "error": ""}},
    {"line": "COPY stage=done part=- bytes=0/0 items=5/5 source=mesh error=settings_refused", "expect": {"stage": "done", "part": "-", "bytes": [0, 0], "items": [5, 5], "source": "mesh", "error": "settings_refused"}},
    {"line": "COPY stage=failed part=notes bytes=0/9000000 items=0/3 source=mesh error=hash_mismatch", "expect": {"stage": "failed", "part": "notes", "bytes": [0, 9000000], "items": [0, 3], "source": "mesh", "error": "hash_mismatch"}},
    {"line": "COPY stage=failed part=- bytes=1000/1092993024 items=0/0 source=mesh error=needs_space", "expect": {"stage": "failed", "part": "-", "bytes": [1000, 1092993024], "items": [0, 0], "source": "mesh", "error": "needs_space"}},
    {"line": "COPY stage=done part=- bytes=0/0 items=1/1 source=mesh later=1", "expect": {"stage": "done", "part": "-", "bytes": [0, 0], "items": [1, 1], "source": "mesh", "error": ""}},
    {"line": "2026/11/05 10:00:00 COPY stage=fetching part=media bytes=1/2 items=0/1 source=mesh", "expect": {"stage": "fetching", "part": "media", "bytes": [1, 2], "items": [0, 1], "source": "mesh", "error": ""}},
    {"line": "COPY stage=paused part=- bytes=0/0 items=0/0 source=mesh", "expect": None},
    {"line": "COPY part=notes stage=fetching bytes=0/1 items=0/1 source=mesh", "expect": None},
    {"line": "COPY stage=fetching part=notes bytes=x/1 items=0/1 source=mesh", "expect": None},
    {"line": "COPY stage=fetching part=photos bytes=0/1 items=0/1 source=mesh", "expect": None},
    {"line": "IMPORT_JOB name=notes state=running", "expect": None},
]})

allow = {"v": 1, "keys": {
    "feed_layouts": {"type": "object<string>", "hex": False, "about": "per-feed layout, feed id -> layout name"},
    "zaps_only": {"type": "bool", "hex": False, "about": "zaps-only mode"},
    "auto_load_new_posts": {"type": "bool", "hex": False, "about": "auto-load new posts"},
    "new_posts_pill": {"type": "bool", "hex": False, "about": "the New Posts pill"},
    "wot_depth": {"type": "int", "hex": False, "min": 0, "max": 3, "about": "web of trust depth"},
    "blocked_relays": {"type": "string[]", "hex": False, "about": "relay URLs never used"},
    "dm_relays": {"type": "string[]", "hex": False, "about": "DM relay choice"},
    "media_servers": {"type": "string[]", "hex": False, "about": "media server choice, in order"},
    "notifications": {"type": "object<bool>", "hex": False, "about": "notification switches, switch name -> on"},
}}
write("settings-allowlist.json", allow)

ok_keys = {"feed_layouts": {"following": "cards", "global": "compact"}, "zaps_only": False, "auto_load_new_posts": True,
           "new_posts_pill": True, "wot_depth": 2, "blocked_relays": ["wss://bad.example"],
           "dm_relays": ["wss://dm.example"], "media_servers": ["https://blossom.example"],
           "notifications": {"replies": True, "zaps": False}}
s = lambda keys, **over: {"v": 1, "updated_at": 1767000000, "keys": keys, **over}
nsec = "nsec1" + "q" * 58
write("settings-refuse-cases.json", {"now": 1767000300, "cases": [
    {"name": "every key, clean", "settings": s(ok_keys), "expect": {"ok": True}},
    {"name": "empty keys", "settings": s({}), "expect": {"ok": True}},
    {"name": "npub in a relay list is fine", "settings": s({"blocked_relays": ["wss://relay.example/npub1" + "q" * 58]}), "expect": {"ok": True}},
    {"name": "63 hex digits are fine", "settings": s({"media_servers": ["https://x.example/" + "a" * 63]}), "expect": {"ok": True}},
    {"name": "nsec in a string", "settings": s({"dm_relays": [nsec]}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "NSEC1 upper case", "settings": s({"dm_relays": [nsec.upper()]}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "ncryptsec in a nested value", "settings": s({"feed_layouts": {"x": "ncryptsec1" + "q" * 40}}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "NWC string", "settings": s({"media_servers": ["nostr+walletconnect://" + h("w") + "?relay=wss://r.example&secret=" + h("s")]}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "bunker string", "settings": s({"dm_relays": ["bunker://" + h("b") + "?relay=wss://r.example"]}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "64-hex string (a raw key)", "settings": s({"feed_layouts": {"k": h("raw key")}}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "64-hex inside a URL", "settings": s({"media_servers": ["https://x.example/" + h("blob")]}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "secret in a map key", "settings": s({"notifications": {nsec: True}}), "expect": {"ok": False, "reason": "secret_value"}},
    {"name": "unknown key (mesh key)", "settings": s({"mesh_nsec": "x"}), "expect": {"ok": False, "reason": "unknown_key"}},
    {"name": "unknown key (my devices)", "settings": s({"my_devices": []}), "expect": {"ok": False, "reason": "unknown_key"}},
    {"name": "bool as string", "settings": s({"zaps_only": "true"}), "expect": {"ok": False, "reason": "bad_type"}},
    {"name": "wot depth out of range", "settings": s({"wot_depth": 9}), "expect": {"ok": False, "reason": "bad_type"}},
    {"name": "wot depth not whole", "settings": s({"wot_depth": 1.5}), "expect": {"ok": False, "reason": "bad_type"}},
    {"name": "list with a number", "settings": s({"dm_relays": ["wss://a.example", 3]}), "expect": {"ok": False, "reason": "bad_type"}},
    {"name": "notifications not bool", "settings": s({"notifications": {"replies": "yes"}}), "expect": {"ok": False, "reason": "bad_type"}},
    {"name": "v2 file", "settings": s(ok_keys, v=2), "expect": {"ok": False, "reason": "bad_version"}},
    {"name": "no updated_at", "settings": {"v": 1, "keys": {}}, "expect": {"ok": False, "reason": "bad_version"}},
    {"name": "dated 11 minutes ahead", "settings": s({}, updated_at=1767000300 + 660), "expect": {"ok": False, "reason": "bad_version"}},
    {"name": "keys missing", "settings": {"v": 1, "updated_at": 1767000000}, "expect": {"ok": False, "reason": "bad_version"}},
], "newest_wins": [
    {"name": "theirs newer", "mine": 100, "theirs": 200, "expect": "theirs"},
    {"name": "mine newer", "mine": 200, "theirs": 100, "expect": "mine"},
    {"name": "tie keeps mine", "mine": 100, "theirs": 100, "expect": "mine"},
    {"name": "none here", "mine": None, "theirs": 100, "expect": "theirs"},
    {"name": "none there", "mine": 100, "theirs": None, "expect": "mine"},
]})

# Media (contract 4, Logen 2026-11-05): every file under a record by one of
# the vault's own keys is the owner's, saved and mirrored photos included; a
# record by any other key is left out. Which notes name a file doesn't matter:
# the events are here to show that.
media_blob, saved_blob, repost_blob, other_blob, draft_blob, dm_blob = (h(x) for x in ["own photo", "saved photo", "reposted photo", "theirs", "draft", "dm file sent"])
write("media-own-uploads-cases.json", {"owner": OWNER, "other": OTHER,
    "records": [{"sha256": b, "pubkey": OWNER} for b in [media_blob, saved_blob, repost_blob, draft_blob, dm_blob]] + [{"sha256": other_blob, "pubkey": OTHER}],
    "events": [
        {"name": "own note with imeta", "pubkey": OWNER, "kind": 1, "content": "look", "tags": [["imeta", f"url https://cdn.example/{media_blob}.jpg", f"x {media_blob}"]]},
        {"name": "someone else's note naming the saved photo", "pubkey": OTHER, "kind": 1, "content": f"https://cdn.example/{saved_blob}.png", "tags": []},
        {"name": "own repost carrying a photo", "pubkey": OWNER, "kind": 6, "content": json.dumps({"content": f"https://cdn.example/{repost_blob}"}), "tags": []},
        {"name": "own note naming a file someone else uploaded", "pubkey": OWNER, "kind": 1, "content": f"https://cdn.example/{other_blob}", "tags": []},
    ],
    "expect_in_media": [media_blob, saved_blob, repost_blob, draft_blob, dm_blob],
    "expect_left_out": {other_blob: "record is not by one of the vault's own keys, even though an own note names it"}})

write("errors-v2.json", {"errors": [
    {"code": "auth_refused", "http": 401, "b": "stop", "line": "Couldn't sign in to {name}"},
    {"code": "not_owner", "http": 403, "b": "stop", "line": "{name} belongs to another account"},
    {"code": "not_found", "http": 404, "b": "restart", "line": ""},
    {"code": "building", "http": 409, "b": "wait", "line": ""},
    {"code": "range", "http": 416, "b": "refetch", "line": ""},
    {"code": "no_space", "http": 507, "b": "relays", "line": "{name} is short of space; copying from your relays instead"},
    {"code": "needs_space", "http": None, "b": "stop", "line": "Needs {need} free, this device has {free}"},
    {"code": "wrong_owner", "http": None, "b": "stop", "line": "{name} belongs to another account"},
    {"code": "unsupported_version", "http": None, "b": "stop", "line": "Update this app to copy from {name}"},
    {"code": "bad_manifest", "http": None, "b": "stop", "line": "{name} sent a copy this app can't read"},
    {"code": "hash_mismatch", "http": None, "b": "restart_next_reconnect", "line": "The copy from {name} arrived damaged; it starts over next time"},
    {"code": "unreachable", "http": None, "b": "resume_next_reconnect", "line": "Waiting for {name}"},
    {"code": "nothing_restored", "http": None, "b": "stop", "line": "Nothing in the copy could be restored"},
    {"code": "settings_refused", "http": None, "b": "continue", "line": "Settings weren't copied: they held something that must stay on {name}"},
    {"code": "cancelled", "http": None, "b": "keep_state", "line": "Copy stopped"},
]})
# §3.4 accounts.json: npubs and names only, never keys.
acct = lambda **over: {"v": 1, "updated_at": 1767000000, "accounts": [{"npub": npub(OWNER), "name": "Owner"}, {"npub": npub(OTHER), "name": "Other"}], **over}
NSEC = _bech32("nsec", bytes.fromhex(h("a secret key")))
bad_npub = npub(OTHER)[:-1] + ("q" if npub(OTHER)[-1] != "q" else "p")
write("accounts-refuse-cases.json", {"cases": [
    {"name": "two accounts", "file": acct(), "expect": ""},
    {"name": "no names", "file": acct(accounts=[{"npub": npub(OWNER)}]), "expect": ""},
    {"name": "a hex key where an npub goes", "file": acct(accounts=[{"npub": OWNER}]), "expect": "secret_value"},
    {"name": "an nsec where an npub goes", "file": acct(accounts=[{"npub": NSEC}]), "expect": "secret_value"},
    {"name": "an nsec in a name", "file": acct(accounts=[{"npub": npub(OWNER), "name": NSEC}]), "expect": "secret_value"},
    {"name": "a key under an extra field", "file": {**acct(), "key": OWNER}, "expect": "secret_value"},
    {"name": "an extra field", "file": {**acct(), "keys": {}}, "expect": "unknown_key"},
    {"name": "an extra field on an account", "file": acct(accounts=[{"npub": npub(OWNER), "relay": "wss://x"}]), "expect": "unknown_key"},
    {"name": "a bad checksum", "file": acct(accounts=[{"npub": bad_npub}]), "expect": "bad_npub"},
    {"name": "an nprofile, not an npub", "file": acct(accounts=[{"npub": _bech32("nprofile", bytes([0, 32]) + bytes.fromhex(OWNER))}]), "expect": "bad_npub"},
    {"name": "v2", "file": acct(v=2), "expect": "bad_version"},
    {"name": "no accounts", "file": acct(accounts=[]), "expect": "too_many"},
    {"name": "65 accounts", "file": acct(accounts=[{"npub": npub(h(f"k{i}"))} for i in range(65)]), "expect": "too_many"},
    {"name": "an 81-character name", "file": acct(accounts=[{"npub": npub(OWNER), "name": "n" * 81}]), "expect": "bad_name"},
]})
write("accounts-merge-cases.json", {"merge": [
    {"name": "theirs adds one", "mine": [{"npub": npub(OWNER), "name": "Owner"}], "theirs": [{"npub": npub(OTHER), "name": "Other"}],
     "expect": [{"npub": npub(OWNER), "name": "Owner"}, {"npub": npub(OTHER), "name": "Other"}]},
    {"name": "never removes", "mine": [{"npub": npub(OWNER)}, {"npub": npub(THIRD)}], "theirs": [{"npub": npub(OWNER)}],
     "expect": [{"npub": npub(OWNER)}, {"npub": npub(THIRD)}]},
    {"name": "my name stays, a missing one is filled", "mine": [{"npub": npub(OWNER), "name": "Me"}, {"npub": npub(OTHER)}],
     "theirs": [{"npub": npub(OWNER), "name": "Owner"}, {"npub": npub(OTHER), "name": "Other"}],
     "expect": [{"npub": npub(OWNER), "name": "Me"}, {"npub": npub(OTHER), "name": "Other"}]},
], "shares": [
    {"name": "one in common", "mine": [OWNER], "theirs": [npub(OTHER), npub(OWNER)], "expect": True},
    {"name": "none in common", "mine": [OWNER], "theirs": [npub(OTHER), npub(THIRD)], "expect": False},
]})
print("ok")
