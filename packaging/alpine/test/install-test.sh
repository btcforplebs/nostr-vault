#!/bin/sh
# Install + start-at-boot test for the nostr-vault apk, inside the OpenRC test container (test/Dockerfile; never a
# box in use). Throwaway keys only (linux/native/test/keytool). Two halves, with a container restart (a reboot)
# between them; .github/workflows/linux-alpine.yml runs:
#   install-test.sh install /root/nv/<apk> <key.rsa.pub>  apk add (signature checked), setup, checks
#   (docker restart)
#   install-test.sh boot                            came back on boot, crash restart, remove keeps data, add again
# Each half exits 1 if any check fails.
set -u
PHASE=${1:-}; KT=${KT:-/root/keytool}; ST=/root/nv-test-state
pass=0; fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
no() { echo "FAIL: $*"; fail=$((fail+1)); }
chk() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
abort() { echo "ABORT: $*"; echo "RESULT pass=$pass fail=$fail (aborted)"; exit 1; }
finish() {
  if [ "$fail" != 0 ]; then
    echo "-- rc-status:"; rc-status -a 2>&1 | tail -20
    for l in /var/log/nostr-vault/*.log; do [ -f "$l" ] && { echo "-- $l"; tail -n 40 "$l"; }; done
  fi
  echo "RESULT $PHASE pass=$pass fail=$fail"; [ "$fail" = 0 ]; exit $?
}
[ "$(id -u)" = 0 ] || abort "run as root"
[ -x "$KT" ] && "$KT" gen | grep -q npub1 || abort "keytool missing or broken (KT=$KT)"
for i in $(seq 1 60); do [ -e /run/openrc/softlevel ] && break; sleep 1; done
[ -e /run/openrc/softlevel ] || abort "OpenRC didn't boot"
D=/var/lib/nostr-vault
pid_of() { # pid_of <name>: the first process with that exact name (from /proc: no procps or busybox applet needed)
  for d in /proc/[0-9]*; do [ "$(cat "$d/comm" 2>/dev/null)" = "$1" ] && { echo "${d#/proc/}"; return 0; }; done; return 1
}
not() { ! "$@"; }
uid_of() { awk '/^Uid:/ {print $2}' "/proc/$(pid_of "$1")/status" 2>/dev/null; }
up() { rc-service -q "$1" status; }
wait_up() { for i in $(seq 1 40); do curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && [ -s $D/mesh/npub ] && pid_of nv-mesh >/dev/null && return 0; sleep 1; done; return 1; }
running_checks() { # what holds whenever the vault is up
  chk "nostr-vault started" up nostr-vault
  chk "nostr-vault-mesh started" up nostr-vault-mesh
  chk "in the default runlevel (starts on boot)" sh -c 'rc-update show default | grep -qw nostr-vault'
  chk "mesh in the default runlevel" sh -c 'rc-update show default | grep -qw nostr-vault-mesh'
  chk "havend runs as nvvault" test "$(uid_of havend)" = "$(id -u nvvault)"
  chk "engine runs as nvvault" test "$(uid_of haven-engine)" = "$(id -u nvvault)"
  chk "nv-mesh runs as nvmesh" test "$(uid_of nv-mesh)" = "$(id -u nvmesh)"
  pv=$(pid_of havend); pm=$(pid_of nv-mesh)
  chk "no caps on havend" grep -q 'CapEff:[[:space:]]*0000000000000000' "/proc/$pv/status"
  chk "no caps on nv-mesh" grep -q 'CapEff:[[:space:]]*0000000000000000' "/proc/$pm/status"
  chk "no new privileges on havend" grep -q 'NoNewPrivs:[[:space:]]*1' "/proc/$pv/status"
  chk "no new privileges on nv-mesh" grep -q 'NoNewPrivs:[[:space:]]*1' "/proc/$pm/status"
  for i in $(seq 1 30); do ss -Hltn "sport = :3355" | grep -q . && break; sleep 1; done
  chk "8080 on all addresses" sh -c "ss -Hltn 'sport = :8080' | awk '{print \$4}' | grep -Eq '^(\*|0.0.0.0|\[::\]):8080'"
  chk "engine 3355 loopback only" sh -c "ss -Hltn 'sport = :3355' | awk '{print \$4}' | grep -q . && ! ss -Hltn 'sport = :3355' | awk '{print \$4}' | grep -vq '^127.0.0.1:'"
  chk "mesh door 8081 loopback only" sh -c "ss -Hltn 'sport = :8081' | awk '{print \$4}' | grep -q . && ! ss -Hltn 'sport = :8081' | awk '{print \$4}' | grep -vq '^127.0.0.1:'"
  chk "web app served on 8080" sh -c "curl -fsS http://127.0.0.1:8080/ | grep -qi '<html'"
  IP=$(hostname -i | awk '{print $1}')
  chk "8080 reachable on the machine's address $IP" curl -fsS -o /dev/null "http://$IP:8080/"
}

case "$PHASE" in
install)
  APK=${2:-}; KEY=${3:-}
  [ -s "$APK" ] && [ -s "$KEY" ] || abort "usage: install-test.sh install <apk> <key.rsa.pub>"
  echo "== Alpine $(cat /etc/alpine-release) $(uname -m), OpenRC $(openrc --version 2>/dev/null | awk '{print $NF}')"
  ss -Hltn 'sport = :8080' | grep -q . && abort "port 8080 is already taken here"
  chk "unsigned-key install is refused (signature checked)" sh -c "! apk add --no-progress -q '$APK'"
  cp "$KEY" /etc/apk/keys/
  if apk add --no-progress "$APK" >/tmp/apk.log 2>&1; then ok "apk add (signed)"; else no "apk add"; tail -20 /tmp/apk.log; finish; fi
  want=$(basename "$APK" | sed -n 's/^nostr-vault-\(.*-r[0-9]*\)\.[a-z0-9_]*\.apk$/\1/p')
  chk "installed version is the apk's ($want)" sh -c "apk info -e nostr-vault && [ -n '$want' ] && apk info nostr-vault 2>/dev/null | grep -qF 'nostr-vault-$want '"
  chk "nv-mesh is a musl binary" sh -c "ldd /usr/lib/nostr-vault/nv-mesh 2>&1 | grep -q ld-musl && ! ldd /usr/lib/nostr-vault/nv-mesh 2>&1 | grep -qi 'not found\|Error'"
  chk "user nvvault uid 10002" test "$(id -u nvvault)" = 10002
  chk "user nvmesh uid 10001" test "$(id -u nvmesh)" = 10001
  chk "vault not running before setup" sh -c '! rc-service -q nostr-vault status'
  chk "vault won't start before setup" sh -c '! rc-service -q nostr-vault start'
  set -- $("$KT" gen); OSK=$1 ONPUB=$2
  echo "throwaway owner $ONPUB"
  chk "setup refuses a bad npub" sh -c '! nostr-vault-setup --owner npub1nope'
  if nostr-vault-setup --owner "$ONPUB" --sd-ok >/tmp/setup.log 2>&1; then ok "setup"; else no "setup"; cat /tmp/setup.log; fi
  wait_up || true
  running_checks
  MNPUB=$(cat $D/mesh/npub 2>/dev/null)
  echo "box mesh npub $MNPUB"
  chk "mesh npub made" sh -c "echo '$MNPUB' | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$'"
  chk "mesh key is not the owner's" test "$MNPUB" != "$ONPUB"
  chk "mesh key owned by nvmesh, 0600" test "$(stat -c '%U %a' $D/mesh/key/nsec)" = "nvmesh 600"
  chk "mesh key dir 0700" test "$(stat -c '%U %a' $D/mesh/key)" = "nvmesh 700"
  chk "vault user cannot read mesh key" sh -c "! su -s /bin/sh nvvault -c 'cat $D/mesh/key/nsec'"
  chk "data dir 0711 nvvault" test "$(stat -c '%U %a' $D)" = "nvvault 711"
  chk "no nsec of the owner on disk" sh -c "! grep -rqs '$OSK' /etc/nostr-vault $D"
  U=http://127.0.0.1:8080/api/box/status
  code=$(curl -s -o /dev/null -w '%{http_code}' $U)
  chk "box API refuses no auth ($code)" test "$code" = 401
  set -- $("$KT" gen); SSK=$1
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $("$KT" auth "$SSK" GET $U)" $U)
  chk "box API refuses a stranger ($code)" test "$code" = 403
  st=$(curl -s -H "Authorization: $("$KT" auth "$OSK" GET $U)" $U)
  echo "-- owner status: $(echo "$st" | head -c 400)"
  chk "box API answers the owner with the box npub" sh -c "[ -n '$MNPUB' ] && echo '$st' | grep -q '$MNPUB'"
  printf 'MNPUB=%s\nOSK=%s\n' "$MNPUB" "$OSK" >"$ST"
  finish ;;
boot)
  [ -s "$ST" ] || abort "no state from the install half"
  . "$ST"
  echo "== after reboot: Alpine $(cat /etc/alpine-release) $(uname -m)"
  wait_up || true
  running_checks
  chk "after reboot: same mesh npub" sh -c "[ -n '$MNPUB' ] && [ \"\$(cat $D/mesh/npub)\" = '$MNPUB' ]"
  U=http://127.0.0.1:8080/api/box/status
  st=$(curl -s -H "Authorization: $("$KT" auth "$OSK" GET $U)" $U)
  chk "after reboot: box API answers the owner" sh -c "echo '$st' | grep -q '$MNPUB'"
  # A crash restarts (supervise-daemon), with the same key.
  kill -9 "$(pid_of nv-mesh)"; sleep 6
  chk "nv-mesh restarted after kill" pid_of nv-mesh
  chk "after mesh restart: same mesh npub" sh -c "[ \"\$(cat $D/mesh/npub)\" = '$MNPUB' ]"
  kill -9 "$(pid_of havend)"; sleep 4; wait_up || true
  chk "havend restarted after kill" pid_of havend
  chk "web app back after the kill" curl -fsS -o /dev/null http://127.0.0.1:8080/
  # Remove stops it and leaves the data (the owner's notes) and the settings.
  apk del --no-progress -q nostr-vault >/dev/null 2>&1 && ok "apk del" || no "apk del"
  chk "after remove: havend stopped" not pid_of havend
  chk "after remove: nv-mesh stopped" not pid_of nv-mesh
  chk "after remove: not in the default runlevel" sh -c '! rc-update show default | grep -qw nostr-vault'
  chk "after remove: data kept" test -s $D/mesh/npub
  # Add it again: it finds its settings, starts by itself on the same key, and is back on boot.
  apk add --no-progress -q /root/nv/nostr-vault-*.apk >/dev/null 2>&1 && ok "apk add again" || no "apk add again"
  wait_up || true
  chk "add again: started by itself" sh -c 'rc-service -q nostr-vault status && rc-service -q nostr-vault-mesh status'
  chk "add again: back in the default runlevel" sh -c 'rc-update show default | grep -qw nostr-vault-mesh'
  chk "add again: same mesh npub" sh -c "[ \"\$(cat $D/mesh/npub)\" = '$MNPUB' ]"
  finish ;;
*) abort "usage: install-test.sh install <apk> <key.rsa.pub> | boot" ;;
esac
