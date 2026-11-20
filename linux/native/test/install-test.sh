#!/bin/sh
# Install test for the nostr-vault package on a real systemd machine (a CI runner, a systemd container or a throwaway
# VM; never a box in use: it installs, starts and reinstalls the vault on port 8080). Throwaway keys only, from keytool
# (test/keytool). The package is a .deb (apt), an .rpm (dnf, Fedora) or a .pkg.tar.zst (pacman, Arch).
#   sudo KT=/path/to/keytool sh linux/native/test/install-test.sh <package> [headless|desktop]
# Exits 1 if any check fails, or if it can't run at all (no package, no keytool, 8080 already taken).
set -u
PKG=${1:-}; MODE=${2:-headless}; KT=${KT:-}
pass=0; fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
no() { echo "FAIL: $*"; fail=$((fail+1)); }
chk() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
abort() { echo "ABORT: $*"; echo "RESULT pass=$pass fail=$fail (aborted)"; exit 1; }
[ "$(id -u)" = 0 ] || abort "run as root"
[ -s "$PKG" ] || abort "no package at '$PKG'"
[ -x "$KT" ] && "$KT" gen | grep -q npub1 || abort "keytool missing or broken (KT=$KT)"
ss -Hltn 'sport = :8080' | grep -q . && abort "port 8080 is already taken here"
export DEBIAN_FRONTEND=noninteractive
echo "== $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m) glibc $(ldd --version | head -1 | awk '{print $NF}')"
# One package manager per package kind: pm_* below are the only places that differ.
case "$PKG" in
  *.deb) PM=apt NV=/tmp/nv.deb ;;
  *.rpm) PM=dnf NV=/tmp/nv.rpm ;;
  *.pkg.tar.zst) PM=pacman NV=/tmp/nv.pkg.tar.zst ;;
  *) abort "not a .deb, .rpm or .pkg.tar.zst: $PKG" ;;
esac
command -v $PM >/dev/null || abort "$PKG needs $PM, and this system has none"
cp "$PKG" "$NV" && chmod 644 "$NV"
pm_file_version() { case $PM in
  apt) dpkg-deb -f "$NV" Version ;;
  dnf) rpm -qp --qf '%{VERSION}-%{RELEASE}' "$NV" ;;
  pacman) pacman -Qp "$NV" | cut -d' ' -f2 ;; esac; }
pm_installed_version() { case $PM in
  apt) dpkg-query -W -f '${Version}' nostr-vault ;;
  dnf) rpm -q --qf '%{VERSION}-%{RELEASE}' nostr-vault ;;
  pacman) pacman -Q nostr-vault | cut -d' ' -f2 ;; esac; }
pm_has() { case $PM in # pm_has <the GTK package's name on apt> <on dnf> <on pacman>
  apt) dpkg -s "$1" 2>/dev/null | grep -q "Status: install ok" ;;
  dnf) rpm -q "$2" >/dev/null 2>&1 ;;
  pacman) pacman -Q "$3" >/dev/null 2>&1 ;; esac; }
pm_install() { case $PM in # pm_install [reinstall]
  apt) if [ -n "${1:-}" ]; then apt-get install -y -q --reinstall "$NV"; else apt-get install -y -q $rec "$NV"; fi ;;
  dnf) if [ -n "${1:-}" ]; then dnf reinstall -y -q "$NV"; else dnf install -y -q $rec "$NV"; fi ;;
  pacman) pacman -U --noconfirm "$NV" ;; esac; }
pm_remove() { case $PM in
  apt) apt-get remove -y -q nostr-vault ;; dnf) dnf remove -y -q nostr-vault ;; pacman) pacman -R --noconfirm nostr-vault ;; esac; }
want=$(pm_file_version)
case $PM in
  apt) apt-get update -q >/dev/null 2>&1
    if [ "$MODE" = desktop ]; then rec=--install-recommends; else rec=--no-install-recommends; fi ;;
  dnf) if [ "$MODE" = desktop ]; then rec=--setopt=install_weak_deps=True; else rec=--setopt=install_weak_deps=False; fi ;;
  pacman) pacman -Sy --noconfirm >/dev/null 2>&1; rec="(the window's packages are depends on Arch)" ;;
esac
if pm_install >/tmp/pm.log 2>&1; then ok "$PM install ($rec)"; else no "$PM install"; tail -15 /tmp/pm.log; echo "RESULT pass=$pass fail=$fail"; exit 1; fi
chk "installed version is the package's ($want)" test "$(pm_installed_version)" = "$want"
chk "user nvvault uid 10002" test "$(id -u nvvault)" = 10002
chk "user nvmesh uid 10001" test "$(id -u nvmesh)" = 10001
chk "vault not running before setup" sh -c '! systemctl -q is-active nostr-vault'
# pacman installs no optional deps, so the Arch package depends on the window's packages: GTK comes with it, by design.
if [ "$PM" = pacman ]; then
  if pm_has - - python-gobject && pm_has - - webkit2gtk-4.1; then ok "pacman: the window's packages came with it"
  else no "pacman: python-gobject or webkit2gtk-4.1 not installed with the package"; fi
elif [ "$MODE" = headless ]; then if pm_has gir1.2-gtk-3.0 gtk3 gtk3; then no "headless: GTK pulled in"; else ok "headless: no GTK pulled in"; fi; fi

set -- $("$KT" gen); OSK=$1 ONPUB=$2
echo "throwaway owner $ONPUB"
chk "setup refuses a bad npub" sh -c '! nostr-vault-setup --owner npub1nope'
if nostr-vault-setup --owner "$ONPUB" --sd-ok >/tmp/setup.log 2>&1; then ok "setup"; else no "setup"; cat /tmp/setup.log; fi
sleep 8
chk "nostr-vault active" systemctl -q is-active nostr-vault
chk "nostr-vault-mesh active" systemctl -q is-active nostr-vault-mesh
chk "enabled on boot" systemctl -q is-enabled nostr-vault
chk "mesh enabled on boot" systemctl -q is-enabled nostr-vault-mesh
D=/var/lib/nostr-vault
for i in $(seq 1 20); do [ -s $D/mesh/npub ] && break; sleep 1; done
MNPUB=$(cat $D/mesh/npub 2>/dev/null)
echo "box mesh npub $MNPUB"
chk "mesh npub made" sh -c "echo '$MNPUB' | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$'"
chk "mesh key is not the owner's" test "$MNPUB" != "$ONPUB"
chk "mesh key owned by nvmesh, 0600" test "$(stat -c '%U %a' $D/mesh/key/nsec)" = "nvmesh 600"
chk "mesh key dir 0700" test "$(stat -c '%U %a' $D/mesh/key)" = "nvmesh 700"
chk "vault user cannot read mesh key" sh -c "! runuser -u nvvault -- cat $D/mesh/key/nsec"
chk "data dir 0711 nvvault" test "$(stat -c '%U %a' $D)" = "nvvault 711"
chk "no nsec of the owner on disk" sh -c "! grep -rqs '$OSK' /etc/nostr-vault $D"
chk "havend runs as nvvault" sh -c "ps -o user= -C havend | grep -qx nvvault"
chk "engine runs as nvvault" sh -c "ps -o user= -C haven-engine | grep -qx nvvault"
chk "nv-mesh runs as nvmesh" sh -c "ps -o user= -C nv-mesh | grep -qx nvmesh"
chk "no caps on havend" sh -c "grep -q 'CapEff:\s*0000000000000000' /proc/\$(pgrep -x havend)/status"
chk "no caps on nv-mesh" sh -c "grep -q 'CapEff:\s*0000000000000000' /proc/\$(pgrep -x nv-mesh)/status"
for i in $(seq 1 30); do ss -Hltn "sport = :3355" | grep -q . && break; sleep 1; done
echo "-- listening:"; ss -Hltnp | grep -E 'havend|haven-engine|nv-mesh' | awk '{print $4, $6}'
chk "8080 on all addresses" sh -c "ss -Hltn 'sport = :8080' | awk '{print \$4}' | grep -Eq '^(\*|0.0.0.0|\[::\]):8080'"
chk "engine 3355 loopback only" sh -c "ss -Hltn 'sport = :3355' | awk '{print \$4}' | grep -q . && ! ss -Hltn 'sport = :3355' | awk '{print \$4}' | grep -vq '^127.0.0.1:'"
chk "mesh door 8081 loopback only" sh -c "ss -Hltn 'sport = :8081' | awk '{print \$4}' | grep -q . && ! ss -Hltn 'sport = :8081' | awk '{print \$4}' | grep -vq '^127.0.0.1:'"
chk "web app served on 8080" sh -c "curl -fsS http://127.0.0.1:8080/ | grep -qi '<html'"
IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
chk "8080 reachable on the machine's address $IP" sh -c "curl -fsS -o /dev/null http://$IP:8080/"
U=http://127.0.0.1:8080/api/box/status
code=$(curl -s -o /dev/null -w '%{http_code}' $U)
chk "box API refuses no auth ($code)" test "$code" = 401
set -- $("$KT" gen); SSK=$1
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $("$KT" auth "$SSK" GET $U)" $U)
chk "box API refuses a stranger ($code)" test "$code" = 403
st=$(curl -s -H "Authorization: $("$KT" auth "$OSK" GET $U)" $U)
echo "-- owner status: $(echo "$st" | head -c 400)"
chk "box API answers the owner with the box npub" sh -c "[ -n '$MNPUB' ] && echo '$st' | grep -q '$MNPUB'"

# Reinstall in place keeps the mesh key; a crash restarts.
pm_install reinstall >/dev/null 2>&1 && ok "reinstall" || no "reinstall"
sleep 6
chk "after reinstall: same mesh npub" sh -c "[ -n '$MNPUB' ] && [ \"\$(cat $D/mesh/npub)\" = '$MNPUB' ]"
chk "after reinstall: vault active" systemctl -q is-active nostr-vault
kill -9 "$(pgrep -x nv-mesh)"; sleep 5
chk "nv-mesh restarted after kill" pgrep -x nv-mesh
chk "after mesh restart: same mesh npub" sh -c "[ -n '$MNPUB' ] && [ \"\$(cat $D/mesh/npub)\" = '$MNPUB' ]"
if [ "$MODE" = desktop ]; then
  chk "desktop entry installed" test -f /usr/share/applications/app.nostrvault.Desktop.desktop
  chk "python gi + webkit present" python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1"); from gi.repository import Gtk, WebKit2'
fi
# Remove leaves the data (the owner's notes) and stops the services.
pm_remove >/dev/null 2>&1 && ok "remove" || no "remove"
chk "after remove: vault stopped" sh -c '! systemctl -q is-active nostr-vault'
chk "after remove: data kept" test -s $D/mesh/npub
chk "after remove: settings kept" grep -q "^NV_OWNER=$ONPUB" /etc/nostr-vault/vault.env
[ "$fail" = 0 ] || journalctl -u nostr-vault -u nostr-vault-mesh --no-pager -n 60
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
