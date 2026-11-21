#!/bin/sh
# supervise.sh's owner rule, run as a normal user with stand-in programs: no owner and no setup code refuses to start;
# a short code refuses; a setup code starts claim mode; box/owner (a claim saved earlier) is the owner; a broken or
# linked box/owner refuses rather than reopening claim mode.
# shellcheck disable=SC2016 # the stand-ins and preps expand later, on purpose
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for p in havend nv-mesh; do
  printf '#!/bin/sh\necho "%s owner=${NV_OWNER:-} code=${NV_SETUP_CODE:-}" >> "%s/ran"\nexec sleep 30\n' "$p" "$tmp" > "$tmp/bin/$p"
  chmod +x "$tmp/bin/$p"
done
npub=npub1xtscya34g58tk0z605fvr788k263gsu6cy9x0mhnm87echrgufzsevkk5s
fail=0

# run <expect: refuse|start> <name> [VAR=value...]: start supervise with a fresh data dir prepared by $prep.
run() {
  want=$1 name=$2; shift 2
  data="$tmp/data-$name"; mkdir -p "$data/box"; rm -f "$tmp/ran"
  [ -z "${prep:-}" ] || eval "$prep"
  env -i PATH="$PATH" NV_DATA_DIR="$data" NV_BIN="$tmp/bin" "$@" sh "$here/supervise.sh" > "$tmp/out" 2>&1 &
  pid=$!
  i=0; while [ $i -lt 30 ] && kill -0 "$pid" 2>/dev/null && [ ! -s "$tmp/ran" ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then got=start; kill -TERM "$pid"; wait "$pid" 2>/dev/null || true; else got=refuse; wait "$pid" 2>/dev/null || true; fi
  if [ "$got" != "$want" ]; then echo "FAIL $name: wanted $want, got $got"; cat "$tmp/out"; fail=1; else echo "ok   $name"; fi
}

prep='' run refuse no-owner-no-code
prep='' run refuse short-code NV_SETUP_CODE=short
prep='' run start claim-mode NV_SETUP_CODE=umbrel-password-0123456789
grep -q "havend owner= code=umbrel-password-0123456789" "$tmp/ran" || { echo "FAIL claim-mode: havend didn't get the code"; fail=1; }
prep='printf "%s\n" "$npub" > "$data/box/owner"' run start owner-file NV_SETUP_CODE=umbrel-password-0123456789
grep -q "havend owner=$npub " "$tmp/ran" || { echo "FAIL owner-file: havend didn't get the saved owner"; cat "$tmp/ran"; fail=1; }
prep='echo garbage > "$data/box/owner"' run refuse broken-owner-file NV_SETUP_CODE=umbrel-password-0123456789
prep='printf "%s\n" "$npub" > "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$data/box/owner"' run refuse linked-owner-file NV_SETUP_CODE=umbrel-password-0123456789
prep='' run start env-owner NV_OWNER=$npub
exit $fail
