# Two-scan device pairing (docs/MESH_PAIRING_CONTRACT.md): the reference the Swift (MeshPairing*.swift), Kotlin
# (fips/MeshPairing*.kt) and web (src/net/mesh-pairing.js) code must agree with. Generates payload-cases.json,
# hello-cases.json and checkwords-cases.json next to it. Run: python3 reference.py
# Every key here is 32 random-looking bytes made for these fixtures (sha256 of a label). None is a real account or
# device, and nothing here signs: signatures and NIP-44 are checked by the app before the session sees a hello.
import hashlib, json, os, base64

HERE = os.path.dirname(os.path.abspath(__file__))
WORDS = open(os.path.join(HERE, "words.txt")).read().split()
assert len(WORDS) == 2048
HELLO_KIND = 21195
CODE_LIFETIME = 180      # A's secret: seconds a hello may open the camera after the QR is shown
SCAN_WINDOW = 180        # seconds A has to scan QR(B) (or Accept) after the hello opened the camera
ACK_WINDOW = 360         # seconds B waits for the ack after scanning QR(A)
HELLO_SKEW = 180         # a hello's t must be within this many seconds of now
NAME_MAX = 40            # Unicode code points
ROLES = ["phone", "mac", "homeVault", "browser"]

# ---- bech32 (BIP-173), npub only ----
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def _polymod(v):
    g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; c = 1
    for x in v:
        b = c >> 25; c = (c & 0x1ffffff) << 5 ^ x
        for i in range(5): c ^= g[i] if (b >> i) & 1 else 0
    return c
def _hrp(h): return [ord(x) >> 5 for x in h] + [0] + [ord(x) & 31 for x in h]
def _bits(data, f, t, pad):
    acc = 0; bits = 0; out = []; mx = (1 << t) - 1
    for v in data:
        acc = (acc << f) | v; bits += f
        while bits >= t: bits -= t; out.append((acc >> bits) & mx)
    if pad and bits: out.append((acc << (t - bits)) & mx)
    elif not pad and (bits >= f or ((acc << (t - bits)) & mx)): return None
    return out
def npub(hexkey):
    d = _bits(bytes.fromhex(hexkey), 8, 5, True)
    c = _polymod(_hrp("npub") + d + [0] * 6) ^ 1
    return "npub1" + "".join(CHARSET[x] for x in d + [(c >> 5 * (5 - i)) & 31 for i in range(6)])
def npub_hex(s):
    """The 32-byte key of an npub, as hex, or None. Upper or lower case, never mixed."""
    if not isinstance(s, str) or (s.lower() != s and s.upper() != s): return None
    s = s.lower()
    if not s.startswith("npub1") or len(s) != 63: return None
    try: d = [CHARSET.index(x) for x in s[5:]]
    except ValueError: return None
    if _polymod(_hrp("npub") + d) != 1: return None
    b = _bits(d[:-6], 5, 8, False)
    return bytes(b).hex() if b is not None and len(b) == 32 else None

# ---- base64url, 16 bytes ----
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
def b64(b): return base64.urlsafe_b64encode(b).decode().rstrip("=")
def unb64_16(s):
    if not isinstance(s, str) or len(s) != 22 or any(c not in B64 for c in s): return None
    b = base64.urlsafe_b64decode(s + "==")
    return b if len(b) == 16 and b64(b) == s else None   # canonical: the last char's spare bits are zero

# ---- percent encoding (RFC 3986 unreserved kept, UTF-8, upper-case hex) ----
UNRESERVED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
def pct(s): return "".join(c if c in UNRESERVED else "".join("%%%02X" % b for b in c.encode()) for c in s)
def unpct(s):
    out = bytearray(); i = 0
    while i < len(s):
        if s[i] == "%":
            h = s[i + 1:i + 3]
            if len(h) != 2 or any(c not in "0123456789abcdefABCDEF" for c in h): return None
            out.append(int(h, 16)); i += 3
        else: out += s[i].encode(); i += 1
    try: return out.decode("utf-8")
    except UnicodeDecodeError: return None

def clean_name(n): return n.strip()[:NAME_MAX] if n else ""   # Python str slices by code point

# ---- the QR ----
def build(m, n, r, o, s=None, e=None, b=None):
    """A's code: `s`. B's code: `e` (A's secret, echoed) and `b` (B's own fresh secret)."""
    q = [("m", m)]
    if clean_name(n): q.append(("n", pct(clean_name(n))))
    q += [("r", r), ("o", o)]
    q += [("s", s)] if s is not None else [("e", e), ("b", b)]
    return "nvpair:v1?" + "&".join(k + "=" + v for k, v in q)

def parse(uri, own=None):
    """-> ("ok", payload) or ("refuse", code). `own` is this device's own mesh npub."""
    u = uri.strip() if isinstance(uri, str) else ""
    if u[:7].lower() != "nvpair:": return ("refuse", "notPairing")
    ver, _, query = u[7:].partition("?")
    if ver != "v1": return ("refuse", "unsupportedVersion")
    fields = {}
    for part in query.split("&") if query else []:
        k, eq, v = part.partition("=")
        if not eq or k in fields: return ("refuse", "malformed")
        dv = unpct(v)
        if dv is None: return ("refuse", "malformed")
        fields[k] = dv
    mh = npub_hex(fields.get("m"))
    if mh is None: return ("refuse", "badAddress")
    if fields.get("r") not in ROLES: return ("refuse", "unknownRole")
    oh = npub_hex(fields.get("o"))
    if oh is None: return ("refuse", "missingOwner")
    # A's code has s and no b; B's has e and b (Tron, PR 1700: b lets B know A really scanned it).
    if ("s" in fields) == ("e" in fields) or ("s" in fields) == ("b" in fields): return ("refuse", "badCode")
    code = fields.get("s", fields.get("e"))
    if unb64_16(code) is None or ("b" in fields and unb64_16(fields["b"]) is None): return ("refuse", "badCode")
    name = fields.get("n", "").strip()
    if len(name) > NAME_MAX: return ("refuse", "nameTooLong")
    if own is not None and npub_hex(own) == mh: return ("refuse", "ownAddress")
    p = {"mesh": npub(mh), "mesh_hex": mh, "name": name, "role": fields["r"], "owner": npub(oh), "owner_hex": oh}
    if "s" in fields: p["secret"] = code
    else: p["echo"] = code; p["b_secret"] = fields["b"]
    return ("ok", p)

def owner_check(owner, active, accounts):
    oh = npub_hex(owner)
    if oh is not None and active is not None and npub_hex(active) == oh: return "ok"
    for a in accounts:
        if oh is not None and npub_hex(a) == oh: return "switchTo:" + a
    return "otherOwner"

def role_check(npub_, role, existing):
    h = npub_hex(npub_)
    for d in existing:
        if npub_hex(d["npub"]) == h:
            return "alreadyLinked" if d["role"] == role else "refuseOtherRole:" + d["role"]
    return "add"

# ---- words people read ----
ROLE_WORD = {"phone": "phone", "mac": "Mac", "homeVault": "home vault", "browser": "browser vault"}
def display(name): return name.strip() if name and name.strip() else "this device"
def role_confirm_text(role, name, setup=False):
    n = display(name)
    if setup: return f"Add {n} as another of your devices: your vault copies between them."
    return {
        "mac": f"Add {n} as your Mac: your vault syncs to it and it keeps a full copy.",
        "homeVault": f"Add {n} as your home vault: your new posts and media are sent to it.",
        "browser": f"Add {n} as your browser vault: it gets your new notes while it's open.",
        "phone": f"Add {n} as another of your phones.",
    }[role]
UNREADABLE = "That code didn't read correctly. Try scanning again."
def refusal_text(code, account_name="", role=""):
    return {
        "notPairing": "That isn't a Nostr Vault pairing code.",
        "unsupportedVersion": "That code is from a newer Nostr Vault. Update this app and try again.",
        "malformed": UNREADABLE, "badAddress": UNREADABLE, "missingOwner": UNREADABLE, "badCode": UNREADABLE,
        "nameTooLong": UNREADABLE,
        "unknownRole": "This version can't link that kind of device. Update this app and try again.",
        "ownAddress": "That's this device's own code.",
        "otherOwner": "That device belongs to another account. Only your own devices can be linked.",
        "switchTo": f"This is {display_account(account_name)}'s device. Switch to {display_account(account_name)} first.",
        "refuseOtherRole": f"This device is already added as your {ROLE_WORD[role] if role in ROLE_WORD else 'device'}. Remove it in Mesh settings first.",
        "alreadyLinked": "Already linked.",
        "expired": "This code has expired. Show a new one.",
        "abort": "Another device tried to use this code. Start again, and only show your code to your own device.",
    }[code]
def display_account(n): return n.strip() if n and n.strip() else "that account"
def short_address(n): return n if len(n) <= 12 else n[:8] + "…" + n[-4:]

# ---- hello and ack (the decrypted content of a kind-21195 event) ----
def hello_json(s, n, r, o, t):
    d = {"v": 1, "s": s}
    if clean_name(n): d["n"] = clean_name(n)
    d.update({"r": r, "o": o, "t": t})
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False)
def ack_json(digest, words=False):
    d = {"v": 1, "ack": True, "d": digest}
    if words: d["w"] = True
    return json.dumps(d, separators=(",", ":"))
def parse_hello(text):
    try: d = json.loads(text)
    except Exception: return None
    if not isinstance(d, dict) or d.get("v") != 1 or d.get("ack") is not None: return None
    s, r, o, t, n = d.get("s"), d.get("r"), d.get("o"), d.get("t"), d.get("n", "")
    if unb64_16(s) is None or r not in ROLES or npub_hex(o) is None: return None
    if type(t) is not int or not isinstance(n, str) or len(n.strip()) > NAME_MAX: return None
    return {"s": s, "n": n.strip(), "r": r, "o": npub(npub_hex(o)), "t": t}
def parse_ack(text):
    try: d = json.loads(text)
    except Exception: return None
    if not isinstance(d, dict) or d.get("v") != 1 or d.get("ack") is not True: return None
    dg = d.get("d")
    if not isinstance(dg, str) or len(dg) != 64 or any(c not in "0123456789abcdef" for c in dg): return None
    w = d.get("w", False)
    if not isinstance(w, bool): return None
    return {"d": dg, "w": w}

def ack_digest(s, ma_hex, mb_hex, sb=None):
    """Scan path: SHA-256(s_A ‖ s_B ‖ m_A ‖ m_B), which only a device that read B's code can make.
    Accept path (`w`): SHA-256(s_A ‖ m_A ‖ m_B), and B also needs its own words tap."""
    return hashlib.sha256(unb64_16(s) + (unb64_16(sb) if sb else b"") + bytes.fromhex(ma_hex) + bytes.fromhex(mb_hex)).hexdigest()
def check_words(ma_hex, mb_hex, s):
    h = hashlib.sha256(bytes.fromhex(ma_hex) + bytes.fromhex(mb_hex) + unb64_16(s)).digest()
    n = int.from_bytes(h[:6], "big") >> 4   # the first 44 bits
    return [WORDS[(n >> (11 * (3 - i))) & 2047] for i in range(4)]

# ---- A's session (shows the code, receives the hello, scans B) ----
class Session:
    def __init__(self, secret, created_at, own_mesh_hex, active, accounts):
        self.secret, self.created, self.own, self.active, self.accounts = secret, created_at, own_mesh_hex, active, accounts
        self.state = "waiting"; self.sender = None; self.hello = None; self.hello_at = None; self.b_secret = None
    def ack(self):
        """The ack content for B once confirmed: proves the scan (s_B), or says Accept (w)."""
        if self.state != "done": return None
        if self.b_secret: return ack_json(ack_digest(self.secret, self.own, self.sender, self.b_secret))
        return ack_json(ack_digest(self.secret, self.own, self.sender), True)
    def receive_hello(self, sender, content, now):
        if self.state in ("done", "expired"): return "expired"
        if self.state == "aborted": return "abort"
        h = parse_hello(content)
        if h is None: return "ignore:notHello"
        if sender == self.own: return "ignore:ownAddress"
        if h["s"] != self.secret: return "ignore:wrongSecret"
        if abs(now - h["t"]) > HELLO_SKEW: return "ignore:stale"
        oc = owner_check(h["o"], self.active, self.accounts)
        if oc != "ok": return "refuse:" + oc.split(":")[0]
        if self.state == "waiting":
            if now - self.created > CODE_LIFETIME: self.state = "expired"; return "expired"
            self.state, self.sender, self.hello, self.hello_at = "camera", sender, h, now
            return "camera"
        if sender == self.sender and h == self.hello: return "ignoreDuplicate"
        self.state = "aborted"; return "abort"
    def _guard(self, now):
        if self.state == "aborted": return "abort"
        if self.state in ("done", "expired"): return "expired"
        if self.state == "waiting": return "reject:notReady"
        if now - self.hello_at > SCAN_WINDOW: self.state = "expired"; return "expired"
        return None
    def accept_qr(self, uri, now):
        g = self._guard(now)
        if g: return g
        kind, p = parse(uri, npub(self.own))
        if kind == "refuse": return "refuse:" + p
        if "secret" in p: return "reject:notTheirCode"
        if p["echo"] != self.secret: return "reject:echoMismatch"
        if p["mesh_hex"] != self.sender or p["role"] != self.hello["r"]: return "reject:notTheDevice"
        self.state = "done"; self.b_secret = p["b_secret"]; return "confirm"
    def accept_without_scan(self, now):
        g = self._guard(now)
        if g: return g
        self.state = "done"; return "confirm"

# ---- B's session (scanned A, shows its QR, waits for the ack) ----
class Joiner:
    def __init__(self, qr_a, own_mesh_hex, own_secret, scanned_at):
        """`own_secret`: s_B, the fresh secret in the code B shows."""
        k, p = parse(qr_a, npub(own_mesh_hex)); assert k == "ok" and "secret" in p
        self.a, self.own, self.at = p, own_mesh_hex, scanned_at
        self.expect_scan = ack_digest(p["secret"], p["mesh_hex"], own_mesh_hex, own_secret)
        self.expect_words = ack_digest(p["secret"], p["mesh_hex"], own_mesh_hex)
        self.state = "waiting"; self.words = False
    def receive_ack(self, sender, content, now):
        if self.state == "linked": return "ignoreDuplicate"
        if self.state == "expired": return "expired"
        a = parse_ack(content)
        if a is None: return "ignore:notAck"
        if sender != self.a["mesh_hex"]: return "ignore:wrongSender"
        if a["d"] != (self.expect_words if a["w"] else self.expect_scan): return "ignore:badDigest"
        if now - self.at > ACK_WINDOW: self.state = "expired"; return "expired"
        if a["w"] and not self.words: self.state = "waitWords"; return "waitWords"
        self.state = "linked"; return "linked"
    def confirm_words(self, now):
        if self.state == "linked": return "ignoreDuplicate"
        if self.state == "expired": return "expired"
        if now - self.at > ACK_WINDOW: self.state = "expired"; return "expired"
        if self.state == "waitWords": self.state = "linked"; return "linked"
        self.words = True; return "waitAck"

# =================================== fixtures ===================================
def key(label): return hashlib.sha256(("nv-pairing-fixture:" + label).encode()).hexdigest()
def sec(label): return b64(hashlib.sha256(("nv-pairing-secret:" + label).encode()).digest()[:16])
SB, SBX = sec("B"), sec("B-other")
A, B, C, OWN = key("A-mac"), key("B-iphone"), key("C-stranger"), key("this-device")
ACC, ACC2, OTHER = key("account-logen-test"), key("account-second"), key("account-stranger")
nA, nB, nC, nOWN, nACC, nACC2, nOTHER = map(npub, (A, B, C, OWN, ACC, ACC2, OTHER))
SA, SX = sec("A"), sec("other")
T0 = 1793800000

parse_cases = []
def pc(name, uri, own=nOWN):
    k, v = parse(uri, own)
    parse_cases.append({"name": name, "uri": uri, "own": own, "expect": {"payload": v} if k == "ok" else {"refusal": v}})
pc("A's QR reads", build(nA, "Logen's Mac", "mac", nACC, s=SA))
pc("B's QR reads", build(nB, "Logen's iPhone", "phone", nACC, e=SA, b=SB))
pc("no name is fine", build(nB, "", "phone", nACC, e=SA, b=SB))
pc("name with spaces, emoji and a quote round-trips", build(nB, "Tess's  iPad 🐝 & co", "phone", nACC, s=SA))
pc("upper-case scheme and npub read", build(nA, "", "mac", nACC, s=SA).replace("nvpair:", "NVPAIR:").replace(nA, nA.upper()))
pc("surrounding whitespace is ignored", "  " + build(nA, "x", "homeVault", nACC, s=SA) + "\n")
pc("unknown extra fields are ignored", build(nA, "x", "browser", nACC, s=SA) + "&z=later")
pc("a plain npub is not a pairing code", nA)
pc("a web link is not a pairing code", "https://nostrvault.app/relay/#owner=" + nACC)
pc("v2 is refused", build(nA, "x", "mac", nACC, s=SA).replace("v1?", "v2?"))
pc("no version is refused", "nvpair:?m=" + nA)
pc("m not an npub", build("npub1notanaddress", "x", "mac", nACC, s=SA))
pc("m with a bad checksum", build(nA[:-1] + ("q" if nA[-1] != "q" else "p"), "x", "mac", nACC, s=SA))
pc("m an nsec-shaped string", build("nsec1" + nA[5:], "x", "mac", nACC, s=SA))
pc("m missing", "nvpair:v1?r=mac&o=" + nACC + "&s=" + SA)
pc("unknown role", build(nA, "x", "fridge", nACC, s=SA))
pc("Android's home_vault spelling is not the wire role", build(nA, "x", "home_vault", nACC, s=SA))
pc("missing role", "nvpair:v1?m=" + nA + "&o=" + nACC + "&s=" + SA)
pc("missing owner", "nvpair:v1?m=" + nA + "&r=mac&s=" + SA)
pc("owner not an npub", build(nA, "x", "mac", "bob", s=SA))
pc("neither s nor e", "nvpair:v1?m=" + nA + "&r=mac&o=" + nACC)
pc("both s and e", build(nA, "x", "mac", nACC, s=SA) + "&e=" + SA)
pc("B's code without b [Tron, PR 1700]", "nvpair:v1?m=" + nB + "&r=phone&o=" + nACC + "&e=" + SA)
pc("A's code with a b", build(nA, "x", "mac", nACC, s=SA) + "&b=" + SB)
pc("B's code with a bad b", build(nB, "x", "phone", nACC, e=SA, b=SB[:-1]))
pc("secret too short", build(nA, "x", "mac", nACC, s=SA[:-2]))
pc("secret with padding", build(nA, "x", "mac", nACC, s=SA + "=="))
pc("secret in standard base64 alphabet", build(nA, "x", "mac", nACC, s="+/" + SA[2:]))
pc("secret not canonical (spare bits set)", build(nA, "x", "mac", nACC, s=SA[:-1] + B64[B64.index(SA[-1]) | 1]))
pc("name over 40 code points", "nvpair:v1?m=" + nA + "&n=" + pct("x" * 41) + "&r=mac&o=" + nACC + "&s=" + SA)
pc("name of exactly 40 emoji is fine", "nvpair:v1?m=" + nA + "&n=" + pct("🐝" * 40) + "&r=mac&o=" + nACC + "&s=" + SA)
pc("bad percent escape", "nvpair:v1?m=" + nA + "&n=%ZZ&r=mac&o=" + nACC + "&s=" + SA)
pc("percent escape that is not UTF-8", "nvpair:v1?m=" + nA + "&n=%FF&r=mac&o=" + nACC + "&s=" + SA)
pc("a field twice", build(nA, "x", "mac", nACC, s=SA) + "&r=phone")
pc("a field with no =", build(nA, "x", "mac", nACC, s=SA) + "&junk")
pc("this device's own address", build(nOWN, "me", "phone", nACC, s=SA))
pc("own address in upper case is still own", build(nOWN.upper(), "me", "phone", nACC, s=SA))
pc("own address check is skipped with no own address", build(nOWN, "me", "phone", nACC, s=SA), None)

build_cases = [
    {"name": "A's code", "args": {"m": nA, "n": "Logen's Mac", "r": "mac", "o": nACC, "s": SA}},
    {"name": "B's code", "args": {"m": nB, "n": "Logen's iPhone", "r": "phone", "o": nACC, "e": SA, "b": SB}},
    {"name": "no name leaves n out", "args": {"m": nB, "n": "   ", "r": "browser", "o": nACC, "e": SA, "b": SB}},
    {"name": "long name is cut to 40 code points", "args": {"m": nA, "n": "🐝" * 50, "r": "homeVault", "o": nACC, "s": SA}},
    {"name": "reserved characters are escaped", "args": {"m": nA, "n": " a&b=c?d/e#f%g+h ", "r": "mac", "o": nACC, "s": SA}},
]
for c in build_cases:
    a = c["args"]; c["expect"] = build(a["m"], a["n"], a["r"], a["o"], a.get("s"), a.get("e"), a.get("b"))

owner_cases = []
for name, o, act, accs in [
    ("matches the active account", nACC, nACC, [nACC, nACC2]),
    ("matches in another case", nACC.upper(), nACC, [nACC]),
    ("matches another account on this device", nACC2, nACC, [nACC, nACC2]),
    ("matches no account", nOTHER, nACC, [nACC, nACC2]),
    ("no active account, one matches", nACC2, None, [nACC2]),
    ("no accounts at all", nACC, None, []),
    ("owner not an npub", "npub1nope", nACC, [nACC]),
]:
    owner_cases.append({"name": name, "owner": o, "active": act, "accounts": accs, "expect": owner_check(o, act, accs)})

existing = [{"npub": nA, "role": "mac"}, {"npub": nC, "role": "phone"}]
role_cases = []
for name, n_, r in [("a new device is added", nB, "phone"), ("the same device, same role, is already linked", nA, "mac"),
                    ("the same device under another role is refused", nA, "homeVault"),
                    ("a phone claimed as the Mac is refused", nC, "mac"), ("case does not matter", nA.upper(), "mac")]:
    role_cases.append({"name": name, "npub": n_, "role": r, "existing": existing, "expect": role_check(n_, r, existing)})

text_cases = []
for r in ROLES:
    for nm in ["Logen's Mac", "  ", ""]:
        text_cases.append({"kind": "confirm", "role": r, "name": nm, "setup": False, "expect": role_confirm_text(r, nm)})
text_cases.append({"kind": "confirm", "role": "phone", "name": "Logen's iPhone", "setup": True, "expect": role_confirm_text("phone", "Logen's iPhone", True)})
text_cases.append({"kind": "confirm", "role": "mac", "name": "", "setup": True, "expect": role_confirm_text("mac", "", True)})
for code in ["notPairing", "unsupportedVersion", "malformed", "badAddress", "missingOwner", "badCode", "nameTooLong",
             "unknownRole", "ownAddress", "otherOwner", "alreadyLinked", "expired", "abort"]:
    text_cases.append({"kind": "refusal", "code": code, "expect": refusal_text(code)})
text_cases.append({"kind": "refusal", "code": "switchTo", "account_name": "Tess", "expect": refusal_text("switchTo", "Tess")})
text_cases.append({"kind": "refusal", "code": "switchTo", "account_name": "", "expect": refusal_text("switchTo", "")})
for r in ROLES:
    text_cases.append({"kind": "refusal", "code": "refuseOtherRole", "role": r, "expect": refusal_text("refuseOtherRole", role=r)})
for n_ in [nA, "npub1short"]:
    text_cases.append({"kind": "short", "npub": n_, "expect": short_address(n_)})

with open(os.path.join(HERE, "payload-cases.json"), "w") as f:
    json.dump({"rule": {"name_max": NAME_MAX, "roles": ROLES}, "parse": parse_cases, "build": build_cases,
               "owner": owner_cases, "role": role_cases, "texts": text_cases}, f, indent=1, ensure_ascii=False)
    f.write("\n")

# ---- session scripts ----
def hello(s=SA, n="Logen's iPhone", r="phone", o=nACC, t=T0 + 10): return hello_json(s, n, r, o, t)
QRB = build(nB, "Logen's iPhone", "phone", nACC, e=SA, b=SB)
def a_case(name, steps, secret=SA, active=nACC, accounts=(nACC, nACC2)):
    s = Session(secret, T0, A, active, list(accounts)); out = []
    for st in steps:
        op = st["op"]
        if op == "hello": got = s.receive_hello(st["sender"], st["content"], st["now"])
        elif op == "qr": got = s.accept_qr(st["uri"], st["now"])
        else: got = s.accept_without_scan(st["now"])
        d = dict(st, expect=got)
        if got == "confirm": d["ack"] = s.ack()
        out.append(d)
    return {"name": name, "side": "shower", "secret": secret, "created_at": T0, "own_mesh": A, "active": active,
            "accounts": list(accounts), "steps": out}
H = lambda sender=B, content=None, now=T0 + 12: {"op": "hello", "sender": sender, "content": content or hello(), "now": now}
Q = lambda uri=QRB, now=T0 + 40: {"op": "qr", "uri": uri, "now": now}
W = lambda now=T0 + 40: {"op": "accept", "now": now}
hello_cases = [
    a_case("happy path: hello, then B's QR", [H(), Q()]),
    a_case("Accept without scanning", [H(), W()]),
    a_case("the same hello twice (a relay resend) is ignored", [H(), H(now=T0 + 15), Q()]),
    a_case("a second sender aborts [Tron 3]", [H(), H(sender=C, content=hello(n="Not yours")), Q()]),
    a_case("the same sender with other content aborts [Tron 3]", [H(), H(content=hello(r="mac")), Q()]),
    a_case("a second hello after the camera window still aborts", [H(), H(sender=C, now=T0 + 300, content=hello(t=T0 + 300))]),
    a_case("wrong secret is ignored, then the right one opens the camera", [H(content=hello(s=SX)), H(), Q()]),
    a_case("a hello after 3 minutes is expired", [H(now=T0 + 181, content=hello(t=T0 + 181))]),
    a_case("a hello at exactly 3 minutes still opens", [H(now=T0 + 180, content=hello(t=T0 + 180)), Q(now=T0 + 200)]),
    a_case("a hello whose own time is stale is ignored", [H(content=hello(t=T0 - 400)), H()]),
    a_case("a hello from the future is ignored", [H(content=hello(t=T0 + 400))]),
    a_case("a hello from another account is refused and does not abort", [H(sender=C, content=hello(o=nOTHER)), H(), Q()]),
    a_case("a hello from another account on this device asks to switch", [H(content=hello(o=nACC2))]),
    a_case("a hello signed by this device's own key is ignored", [H(sender=A)]),
    a_case("garbage content is ignored", [H(content="not json"), H(content='{"v":2}'), H()]),
    a_case("an ack is not a hello", [H(content=ack_json("0" * 64)), H()]),
    a_case("a hello with an unknown role is ignored", [H(content=hello(r="fridge"))]),
    a_case("a hello with a name over 40 is ignored", [H(content=json.dumps({"v": 1, "s": SA, "n": "x" * 41, "r": "phone", "o": nACC, "t": T0 + 10}))]),
    a_case("B's QR before any hello is not ready", [Q(), H(), Q()]),
    a_case("B's QR from another device is refused", [H(), Q(uri=build(nC, "x", "phone", nACC, e=SA, b=SB)), Q()]),
    a_case("B's QR with the wrong echo is refused", [H(), Q(uri=build(nB, "x", "phone", nACC, e=SX, b=SB))]),
    a_case("B's QR with another role than the hello is refused", [H(), Q(uri=build(nB, "x", "mac", nACC, e=SA, b=SB))]),
    a_case("scanning A-type code (a secret, not an echo) is refused", [H(), Q(uri=build(nB, "x", "phone", nACC, s=SA))]),
    a_case("an unreadable second QR says why", [H(), Q(uri="hello there")]),
    a_case("scanning this device's own code is refused", [H(), Q(uri=build(nA, "x", "mac", nACC, e=SA, b=SB))]),
    a_case("B's QR after the scan window is expired", [H(), Q(now=T0 + 12 + 181)]),
    a_case("after linking, the code is spent", [H(), Q(), H(now=T0 + 50), Q(now=T0 + 51), W(now=T0 + 52)]),
    a_case("after an abort, nothing links", [H(), H(sender=C), Q(), W()]),
    a_case("after expiry, a later hello is still expired", [H(now=T0 + 200, content=hello(t=T0 + 200)), H(now=T0 + 201, content=hello(t=T0 + 201))]),
]

def b_case(name, steps, qr_a=None, scanned_at=T0 + 10):
    qa = qr_a or build(nA, "Logen's Mac", "mac", nACC, s=SA)
    j = Joiner(qa, B, SB, scanned_at); out = []
    for st in steps:
        got = j.receive_ack(st["sender"], st["content"], st["now"]) if st["op"] == "ack" else j.confirm_words(st["now"])
        out.append(dict(st, expect=got))
    return {"name": name, "side": "joiner", "qr_a": qa, "own_mesh": B, "own_secret": SB, "scanned_at": scanned_at, "steps": out}
GOOD = ack_digest(SA, A, B, SB)     # scan path
WGOOD = ack_digest(SA, A, B)        # Accept path, with w
K = lambda content=None, sender=A, now=T0 + 40: {"op": "ack", "sender": sender, "content": content or ack_json(GOOD), "now": now}
WD = lambda now=T0 + 45: {"op": "words", "now": now}
hello_cases += [
    b_case("ack after a scan links", [K()]),
    b_case("a second ack is a duplicate", [K(), K(now=T0 + 41)]),
    b_case("Accept path: ack first, then this side's own tap [Tron 2]", [K(content=ack_json(WGOOD, True)), WD()]),
    b_case("Accept path: own tap first, then the ack", [WD(), K(content=ack_json(WGOOD, True))]),
    b_case("forged scan ack: no w, no s_B (A never read B's code) [Tron, PR 1700]", [K(content=ack_json(WGOOD)), K()]),
    b_case("scan ack with the wrong s_B is ignored [Tron, PR 1700]", [K(content=ack_json(ack_digest(SA, A, B, SBX))), K()]),
    b_case("w with the scan digest is ignored", [K(content=ack_json(GOOD, True))]),
    b_case("the words tap after 6 minutes is expired", [K(content=ack_json(WGOOD, True)), WD(now=T0 + 10 + 361), K(content=ack_json(WGOOD, True), now=T0 + 10 + 362)]),
    b_case("the words tap at exactly 6 minutes links", [K(content=ack_json(WGOOD, True)), WD(now=T0 + 10 + 360)]),
    b_case("an ack from another key is ignored", [K(sender=C), K()]),
    b_case("an ack with A and B swapped is ignored [Tron 2]", [K(content=ack_json(ack_digest(SA, B, A))), K()]),
    b_case("an ack for another secret is ignored [Tron 2]", [K(content=ack_json(ack_digest(SX, A, B)))]),
    b_case("a hello is not an ack", [K(content=hello())]),
    b_case("an ack with an upper-case digest is not read", [K(content=ack_json(GOOD.upper()))]),
    b_case("an ack after 6 minutes is expired", [K(now=T0 + 10 + 361), K(now=T0 + 10 + 362)]),
    b_case("an ack at exactly 6 minutes links", [K(now=T0 + 10 + 360)]),
]
with open(os.path.join(HERE, "hello-cases.json"), "w") as f:
    json.dump({"rule": {"hello_kind": HELLO_KIND, "code_lifetime": CODE_LIFETIME, "scan_window": SCAN_WINDOW,
                        "ack_window": ACK_WINDOW, "hello_skew": HELLO_SKEW},
               "builders": [{"kind": "hello", "args": {"s": SA, "n": "  Logen's iPhone 🐝 ", "r": "phone", "o": nACC, "t": T0},
                             "expect": hello_json(SA, "  Logen's iPhone 🐝 ", "phone", nACC, T0)},
                            {"kind": "hello", "args": {"s": SA, "n": "", "r": "mac", "o": nACC, "t": T0},
                             "expect": hello_json(SA, "", "mac", nACC, T0)},
                            {"kind": "ack", "args": {"d": GOOD, "w": False}, "expect": ack_json(GOOD)},
                            {"kind": "ack", "args": {"d": WGOOD, "w": True}, "expect": ack_json(WGOOD, True)}],
               "cases": hello_cases}, f, indent=1, ensure_ascii=False)
    f.write("\n")

cw = []
for la, lb, ls in [("A-mac", "B-iphone", "A"), ("A-mac", "B-iphone", "other"), ("B-iphone", "A-mac", "A"), ("C-stranger", "B-iphone", "A")]:
    a, b, s = key(la), key(lb), sec(ls)
    cw.append({"a": a, "b": b, "secret": s, "words": check_words(a, b, s), "ack_digest": ack_digest(s, a, b),
               "b_secret": SB, "ack_digest_scan": ack_digest(s, a, b, SB)})
cw.append({"a": "00" * 32, "b": "ff" * 32, "secret": b64(bytes(16)), "words": check_words("00" * 32, "ff" * 32, b64(bytes(16))),
           "ack_digest": ack_digest(b64(bytes(16)), "00" * 32, "ff" * 32),
           "b_secret": b64(b"\xff" * 16), "ack_digest_scan": ack_digest(b64(bytes(16)), "00" * 32, "ff" * 32, b64(b"\xff" * 16))})
with open(os.path.join(HERE, "checkwords-cases.json"), "w") as f:
    json.dump({"rule": {"words": 4, "bits_per_word": 11, "list": "BIP-39 English (words.txt, CRC32 c1dbd296)",
                        "list_sha256": hashlib.sha256(open(os.path.join(HERE, "words.txt"), "rb").read()).hexdigest()},
               "cases": cw}, f, indent=1)
    f.write("\n")
print("parse", len(parse_cases), "build", len(build_cases), "owner", len(owner_cases), "role", len(role_cases),
      "texts", len(text_cases), "sessions", len(hello_cases), "words", len(cw))
