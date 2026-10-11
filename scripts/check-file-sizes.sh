#!/usr/bin/env bash
# Enforces the file-size rule in AGENTS.md: a .swift or .kt file over 1,000
# lines must not grow, and no file may grow past 1,000 lines.
# Usage: scripts/check-file-sizes.sh <base-ref>   (default: origin/master)
set -euo pipefail

base="${1:-origin/master}"
limit=1000
fail=0

lines() { if git cat-file -e "$1" 2>/dev/null; then git show "$1" | wc -l | tr -d " "; else echo 0; fi; }

while IFS= read -r f; do
  case "$f" in *.swift|*.kt) ;; *) continue ;; esac
  [ -f "$f" ] || continue
  after=$(wc -l < "$f" | tr -d ' ')
  before=$(lines "$base:$f")
  if [ "$after" -gt "$limit" ] && [ "$after" -gt "$before" ]; then
    if [ "$before" -gt "$limit" ]; then
      echo "::error file=$f::$f is over $limit lines and grew from $before to $after. Put the new code in a new file (see AGENTS.md, Code structure rules)."
    else
      echo "::error file=$f::$f grew from $before to $after lines, past the $limit-line limit. Put the new code in a new file (see AGENTS.md, Code structure rules)."
    fi
    fail=1
  fi
done < <(git diff --name-only --diff-filter=AM "$(git merge-base "$base" HEAD)" HEAD)

if [ "$fail" -eq 0 ]; then echo "File sizes OK."; fi
exit "$fail"
