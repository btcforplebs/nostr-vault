#!/usr/bin/env python3
"""Builds app/src/main/assets/emoji/emoji.tsv from Unicode's emoji-test.txt.

Usage: python3 tools/gen_emoji_tsv.py <emoji-test.txt> > app/src/main/assets/emoji/emoji.tsv
Source: https://unicode.org/Public/emoji/latest/emoji-test.txt

Keeps fully-qualified emoji in Unicode order, one "# group: <name>" line per
group, then "<emoji>\t<name>". Drops the Component group and skin-tone
variants (the picker shows the base emoji). The app hides any emoji the
phone's font cannot draw, so a newer list than the phone is safe.
"""
import re
import sys

SKIN = set(range(0x1F3FB, 0x1F400))

def main(path):
    version = date = ""
    group = None
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# Version:"):
                version = line.split(":", 1)[1].strip()
            elif line.startswith("# Date:"):
                date = line.split(":", 1)[1].strip()
            elif line.startswith("# group:"):
                group = line.split(":", 1)[1].strip()
                if group != "Component":
                    out.append("# group: " + group)
            elif line and not line.startswith("#") and group != "Component":
                m = re.match(r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$", line)
                if not m:
                    continue
                cps = [int(c, 16) for c in m.group(1).split()]
                if any(c in SKIN for c in cps):
                    continue
                out.append(m.group(2) + "\t" + m.group(3).strip())
    print("# Unicode emoji-test.txt, version %s (%s). Built by tools/gen_emoji_tsv.py." % (version, date))
    print("\n".join(out))

if __name__ == "__main__":
    main(sys.argv[1])
