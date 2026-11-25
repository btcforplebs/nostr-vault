"""The tray icon is the Mac app's menu bar glyph: the path in linux/native/desktop/nostr-vault-tray.svg must be the one
in HavenApp/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.pdf, number for number, so a new Mac glyph
can't leave Linux on the old one. Exits 1 when they differ.
  python3 -I tray-icon-test.py [<repo root>]"""
import os
import re
import sys
import zlib

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../..")
pdf = open(os.path.join(root, "HavenApp/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.pdf"), "rb").read()
svg = open(os.path.join(root, "linux/native/desktop/nostr-vault-tray.svg"), encoding="utf-8").read()

# The PDF's page: one filled path (m, l, c, h operators, then f* = even-odd fill), on an 18x18 page.
box = re.search(rb"/MediaBox \[([^\]]*)\]", pdf).group(1).split()
content = zlib.decompress(re.search(rb"stream\r?\n(.*?)endstream", pdf, re.S).group(1)).decode("latin1")
ops = content.split("sc", 1)[1].rsplit("f*", 1)[0].split()
want, nums = [], []
for tok in ops:
    if tok in ("m", "l", "c", "h"):
        want.append(({"m": "M", "l": "L", "c": "C", "h": "Z"}[tok], [float(n) for n in nums]))
        nums = []
    else:
        nums.append(tok)

m = re.search(r'<path [^>]*\bd="([^"]*)"', svg)
try:  # only M, L, C and Z, absolute, as the PDF has them: anything else (another glyph's path) isn't this one
    got = [(c, [float(n) for n in a.split()]) for c, a in re.findall(r"([MLCZ])([^MLCZ]*)", m.group(1) if m else "")]
except ValueError:
    got = None
fails = []
if got != want:
    n = "unreadable" if got is None else len(got)
    fails.append(f"the tray's path ({n} commands) isn't the Mac glyph's ({len(want)} commands)")
if 'viewBox="%s"' % " ".join(b.decode() for b in box) not in svg:
    fails.append("the tray's viewBox isn't the PDF's page (%s)" % b" ".join(box).decode())
if 'transform="matrix(1 0 0 -1 0 %s)"' % box[3].decode() not in svg:
    fails.append("the path isn't flipped from the PDF's y-up")
if 'fill-rule="evenodd"' not in svg:
    fails.append("the fill isn't even-odd (the PDF's f*): the arch would fill solid")
for f in fails:
    print("FAIL: " + f)
if not fails:
    print(f"PASS: the tray icon is the Mac menu bar glyph ({len(want)} path commands)")
sys.exit(1 if fails else 0)
