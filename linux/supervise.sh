#!/bin/sh
# The box's one supervisor (tini runs it as PID 1's child): starts havend and the mesh process, starts either again
# when it exits, and stops both when the container stops. A program that keeps dying waits longer each time (1 s,
# doubling, at most 30 s); one that ran a minute starts over at 1 s. Both run at low CPU priority (nice 10), so a
# small board stays usable for its other jobs.
set -eu

: "${NV_DATA_DIR:=/data}" "${NV_PORT:=8080}" "${NV_BIN:=/app/bin}"
export NV_DATA_DIR NV_PORT

# The owner is set by install.sh, never claimed by whoever visits first: no owner, no box.
case "${NV_OWNER:-}" in
  npub1*) printf '%s' "$NV_OWNER" | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$' || { echo "supervise: NV_OWNER isn't a valid npub" >&2; exit 64; } ;;
  *) printf '%s' "${NV_OWNER:-}" | grep -Eq '^[0-9a-f]{64}$' || { echo "supervise: NV_OWNER must be the owner's npub (set by install.sh)" >&2; exit 64; } ;;
esac
[ -d "$NV_DATA_DIR" ] && [ -w "$NV_DATA_DIR" ] || { echo "supervise: $NV_DATA_DIR isn't a writable directory" >&2; exit 65; }

pids=""
stopping=0

# keep <name> <command...>: run it, and run it again whenever it exits, until the container stops.
keep() {
  name=$1; shift
  (
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
    wait_s=1
    while :; do
      started=$(date +%s)
      nice -n 10 "$@" &
      child=$!
      code=0; wait "$child" || code=$?
      ran=$(( $(date +%s) - started ))
      [ "$ran" -ge 60 ] && wait_s=1
      echo "supervise: $name exited ($code) after ${ran}s, starting it again in ${wait_s}s" >&2
      sleep "$wait_s"
      wait_s=$(( wait_s * 2 )); [ "$wait_s" -gt 30 ] && wait_s=30
    done
  ) &
  pids="$pids $!"
}

stop() {
  [ "$stopping" = 1 ] && return
  stopping=1
  echo "supervise: stopping" >&2
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  exit 0
}
trap stop TERM INT

keep havend "$NV_BIN/havend"
keep nv-mesh "$NV_BIN/nv-mesh"
echo "supervise: havend and nv-mesh started, box on port $NV_PORT, data in $NV_DATA_DIR" >&2
# Wait for a signal; `wait` returns on each one, so loop. A keeper that is gone (it never should be) ends the box, so
# Docker's restart policy starts it whole again rather than this loop spinning.
while :; do
  wait || true
  for p in $pids; do kill -0 "$p" 2>/dev/null || { echo "supervise: a keeper died, stopping the box" >&2; stop; }; done
done
