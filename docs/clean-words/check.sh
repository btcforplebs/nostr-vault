#!/usr/bin/env bash
# Checks the clean mode word list and every app's copy of it.
# 1. docs/clean-words/en.txt is well formed: one lowercase a-z word per line,
#    sorted (LC_ALL=C), no duplicates, no blank lines, ends with a newline.
# 2. Each app copy that exists is byte-identical to it. A copy that does not
#    exist yet is reported and skipped, so this passes before an app adopts it.
#    Set CLEAN_WORDS_REQUIRE_ALL=1 to fail on a missing copy instead.
# Usage: docs/clean-words/check.sh   (from anywhere inside the repo)
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
src="docs/clean-words/en.txt"
# The app copies. Add a line here when a platform adopts the list.
copies=(
  "web-vault/src/net/clean-words-en.txt"
  "NostrVault/app/src/main/assets/clean-words-en.txt"
  "HavenApp/HavenApp/Resources/clean-words-en.txt"
)

cd "$root"
fail=0
err() { echo "::error file=$1::$2"; fail=1; }

[ -s "$src" ] || { err "$src" "$src is missing or empty"; exit 1; }

bad=$(LC_ALL=C grep -nv '^[a-z][a-z]*$' "$src" || true)
[ -z "$bad" ] || err "$src" "lines that are not one lowercase a-z word: $(echo "$bad" | head -5 | tr '\n' ' ')"

if ! LC_ALL=C sort -c -u "$src" 2>/dev/null; then
  err "$src" "$src must be sorted with LC_ALL=C sort -u (no duplicates)"
fi

[ "$(tail -c 1 "$src" | od -An -c | tr -d ' ')" = '\n' ] || err "$src" "$src must end with a newline"

for c in "${copies[@]}"; do
  if [ ! -e "$c" ]; then
    if [ "${CLEAN_WORDS_REQUIRE_ALL:-0}" = 1 ]; then err "$c" "$c is missing"; else echo "skip: $c (not added yet)"; fi
    continue
  fi
  if cmp -s "$src" "$c"; then echo "ok:   $c"; else err "$c" "$c differs from $src. Copy it again: cp $src $c"; fi
done

n=$(wc -l < "$src" | tr -d ' ')
[ "$fail" = 0 ] && echo "clean words: $n entries, all copies match"
exit "$fail"
