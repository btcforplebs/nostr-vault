#!/bin/sh
# The box's one supervisor (under tini). It starts as root only to set up /data, then runs each program as its own
# user with no privileges left (setpriv: no capabilities, no new privileges):
#   havend   uid 10002 "vault"   the vault, the box API and the web app on NV_PORT
#   nv-mesh  uid 10001 "nvmesh"  the mesh; its key (mesh/key/) is readable by it alone (linux/mesh/README.md)
# Either one is started again when it exits: after 1 s, doubling to 30 s, back to 1 s once it ran a minute. Both
# run at nice 10, so a small board stays usable for its other jobs. `docker stop` stops both.
set -eu

: "${NV_DATA_DIR:=/data}" "${NV_PORT:=8080}" "${NV_BIN:=/app/bin}"
export NV_DATA_DIR NV_PORT
VAULT_UID=10002 MESH_UID=10001

# The owner is set by install.sh, never claimed by whoever visits first: no owner, no box.
case "${NV_OWNER:-}" in
  npub1*) printf '%s' "$NV_OWNER" | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$' || { echo "supervise: NV_OWNER isn't a valid npub" >&2; exit 64; } ;;
  *) printf '%s' "${NV_OWNER:-}" | grep -Eq '^[0-9a-f]{64}$' || { echo "supervise: NV_OWNER must be the owner's npub (set by install.sh)" >&2; exit 64; } ;;
esac
[ -d "$NV_DATA_DIR" ] || { echo "supervise: $NV_DATA_DIR isn't there" >&2; exit 65; }

# /data: havend's (it writes box/, vault/ and mesh-devices.json), mode 0711 so nv-mesh can reach mesh/ but not list
# the rest. mesh/: nv-mesh's (it makes key/ 0700 inside, and writes npub and status.json for havend to read).
# Only the two top folders are set: the rest is left as the programs made it.
if [ "$(id -u)" = 0 ]; then
  chown "$VAULT_UID:$VAULT_UID" "$NV_DATA_DIR" && chmod 711 "$NV_DATA_DIR"
  mkdir -p "$NV_DATA_DIR/mesh"
  chown "$MESH_UID:$MESH_UID" "$NV_DATA_DIR/mesh" && chmod 755 "$NV_DATA_DIR/mesh"
  ROOT=1
else
  echo "supervise: not root, so havend and nv-mesh share uid $(id -u) and the mesh key isn't kept from havend" >&2
  ROOT=0
fi

pids=""
stopping=0

# keep <name> <uid> <command...>: run it as <uid>, and run it again whenever it exits, until the container stops.
keep() {
  name=$1 uid=$2; shift 2
  (
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
    wait_s=1
    while :; do
      started=$(date +%s)
      if [ "$ROOT" = 1 ]; then
        nice -n 10 setpriv --reuid="$uid" --regid="$uid" --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs -- "$@" &
      else
        nice -n 10 "$@" &
      fi
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

keep havend "$VAULT_UID" "$NV_BIN/havend"
keep nv-mesh "$MESH_UID" "$NV_BIN/nv-mesh"
echo "supervise: havend and nv-mesh started, box on port $NV_PORT, data in $NV_DATA_DIR" >&2
# Wait for a signal; `wait` returns on each one, so loop. A keeper that is gone (it never should be) ends the box, so
# Docker's restart policy starts it whole again rather than this loop spinning.
while :; do
  wait || true
  for p in $pids; do kill -0 "$p" 2>/dev/null || { echo "supervise: a keeper died, stopping the box" >&2; stop; }; done
done
