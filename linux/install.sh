#!/bin/sh
# Install Nostr Vault on a Linux machine (a Raspberry Pi, a mini PC, a home server, a desktop):
#   curl -fsSL https://raw.githubusercontent.com/btcforplebs/nostr-vault/master/linux/install.sh | sh
# It asks where your vault should live and whose it is (your npub), starts the vault, and prints the address to open
# on your local network. Run it again to change either answer or to update: the vault's data stays where it is.
# Nothing here opens a port on your router.
#
# Two ways to run the vault:
#   native (the default where there is apt, dnf or pacman: Debian, Ubuntu, Raspberry Pi OS, Fedora, Arch): the
#     nostr-vault package (.deb, .rpm or Arch package), system services that start on boot, and on a desktop also a
#     window and a tray icon, like the Mac app. No Docker.
#   Docker (NV_DOCKER=1, or when this machine already runs the Docker box): one container, as before. NV_NATIVE=1
#     moves a Docker box to native on the same data, owner and port.
#
# Every question can be answered ahead (for scripts): NV_DATA_HOST=/path NV_OWNER=npub1… NV_YES=1. Also:
#   NV_PORT (8080), NV_DESKTOP (1/0: the window's libraries; default: when this machine has a desktop),
#   NV_DEB_DIR (install the package from this folder), NV_RELEASE (where the packages and their manifest are:
#   default the latest GitHub release; GitHub's "latest" never points at a pre-release, so a beta needs its tag:
#   https://github.com/btcforplebs/nostr-vault/releases/download/<tag>). Docker only: NV_IMAGE (the image), NV_HOME (/opt/nostr-vault: compose.yml and .env),
#   NV_SOURCE (where compose.yml comes from: a URL, or a directory), NV_IMAGE_TAR (load the image from a file).
set -eu

NV_HOME=${NV_HOME:-/opt/nostr-vault}
NV_SOURCE=${NV_SOURCE:-https://raw.githubusercontent.com/btcforplebs/nostr-vault/master/linux}
NV_IMAGE=${NV_IMAGE:-ghcr.io/btcforplebs/nostr-vault-linux:latest}
NV_RELEASE=${NV_RELEASE:-https://github.com/btcforplebs/nostr-vault/releases/latest/download}
NATIVE_ENV=/etc/nostr-vault/vault.env
VAULT_UID=10002 # havend's user inside the image (linux/Dockerfile); the box's supervisor sets up the rest of /data

say() { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf 'Stopped: %s\n' "$*" >&2; exit 1; }

# Run as root, or through sudo.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "run this as root, or install sudo"
  SUDO=sudo
fi

# Questions read the terminal, not stdin (stdin is this script when it's piped from curl).
TTY=""
if [ "${NV_YES:-0}" != 1 ] && (: </dev/tty) 2>/dev/null; then TTY=/dev/tty; fi
# ask <question> <default>: the answer, or the default when it's left empty (or nobody can be asked).
ask() {
  if [ -z "$TTY" ]; then printf '%s' "$2"; return; fi
  if [ -n "$2" ]; then printf '%s [%s]: ' "$1" "$2" >/dev/tty; else printf '%s: ' "$1" >/dev/tty; fi
  read -r a </dev/tty || a=""
  printf '%s' "${a:-$2}"
}
yes_no() { # yes_no <question>: true for y/yes; no (and unattended runs) is false unless NV_YES=1
  [ "${NV_YES:-0}" = 1 ] && return 0
  [ -n "$TTY" ] || return 1
  case "$(ask "$1 (y/N)" "")" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# 1. This machine.
[ "$(uname -s)" = Linux ] || die "this installer is for Linux"
case "$(uname -m)" in
  aarch64|arm64) arch=arm64 m=aarch64 ;;
  x86_64|amd64) arch=amd64 m=x86_64 ;;
  *) die "Nostr Vault runs on 64-bit ARM or x86 machines; this one is $(uname -m)" ;;
esac
say "Nostr Vault for Linux ($arch)"

# Native or Docker. A machine already running the Docker box stays on Docker unless NV_NATIVE=1 says to move.
docker_box=0; [ -f "$NV_HOME/compose.yml" ] && docker_box=1
if [ "${NV_DOCKER:-0}" = 1 ]; then mode=docker
elif [ "${NV_NATIVE:-0}" = 1 ]; then mode=native
elif [ "$docker_box" = 1 ] && [ ! -f "$NATIVE_ENV" ]; then
  mode=docker
  say "This machine runs the Docker box, so this updates it. To move it to the native app (same data): NV_NATIVE=1"
else mode=native
fi
# The package manager picks the package: apt the .deb, dnf the .rpm, pacman the Arch package. pkg_name is the file's
# name in the release (and its manifest) for a version.
pm=""
if command -v apt-get >/dev/null 2>&1; then pm=apt
elif command -v dnf >/dev/null 2>&1; then pm=dnf
elif command -v pacman >/dev/null 2>&1; then pm=pacman
fi
pkg_name() { case $pm in
  apt) printf 'nostr-vault_%s_%s.deb' "$1" "$arch" ;;
  dnf) printf 'nostr-vault-%s-1.%s.rpm' "$1" "$m" ;;
  pacman) printf 'nostr-vault-%s-1-%s.pkg.tar.zst' "$1" "$m" ;; esac; }
if [ "$mode" = native ] && [ -z "$pm" ]; then
  [ "${NV_NATIVE:-0}" = 1 ] && die "the native app is a package for apt, dnf or pacman (Debian, Ubuntu, Raspberry Pi OS, Fedora, Arch); on this system use Docker: NV_DOCKER=1"
  say "This system has no apt, dnf or pacman, so the vault runs in Docker."
  mode=docker
fi
# Native is the default only once a release carries this system's package: until then (or if GitHub can't be
# reached) the installer keeps the Docker box, as before, rather than failing. (A release can carry the .deb only.)
# A machine already on native never falls back: it gets the plain error further down.
if [ "$mode" = native ] && [ -z "${NV_DEB_DIR:-}" ] && [ "${NV_NATIVE:-0}" != 1 ] && [ ! -f "$NATIVE_ENV" ]; then
  mf=$(curl -fsSL --proto '=https' "$NV_RELEASE/nostr-vault-linux.json" 2>/dev/null || true)
  if ! printf '%s' "$mf" | grep -q "\"$(pkg_name '[^"]*')\""; then
    say "No native package for this system in the release yet, so the vault runs in Docker. (NV_NATIVE=1 insists on native.)"
    mode=docker
  fi
fi

# Values from an earlier install are the defaults this time: the native one's, else the Docker box's.
old() {
  v=""
  if [ "$mode" = native ] && [ -r "$NATIVE_ENV" ]; then
    k=$1; [ "$k" = NV_DATA_HOST ] && k=NV_DATA_DIR
    v=$(sed -n "s/^$k=//p" "$NATIVE_ENV" | tail -1)
  fi
  [ -n "$v" ] || v=$($SUDO cat "$NV_HOME/.env" 2>/dev/null | sed -n "s/^$1=//p" | tail -1)
  printf '%s' "$v"
}

# 2. Docker (the Docker way only).
if [ "$mode" = docker ] && ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker (from get.docker.com)…"
  command -v curl >/dev/null 2>&1 || die "curl is needed to install Docker"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
if [ "$mode" = docker ] && ! $SUDO docker info >/dev/null 2>&1; then
  if [ -d /run/systemd/system ]; then $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  else $SUDO service docker start >/dev/null 2>&1 || true
  fi
  i=0; until $SUDO docker info >/dev/null 2>&1; do i=$((i + 1)); [ $i -gt 30 ] && die "Docker isn't running (try: sudo systemctl start docker)"; sleep 1; done
fi
[ "$mode" = native ] || $SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose is missing (on Debian or Ubuntu: sudo apt-get install docker-compose-plugin)"

# 3. Where the vault lives. Suggested: the drive with the most free space.
biggest() { # a real drive's mount point (a directory: a single file can be bind-mounted too), most free space first
  df -P -k 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/dev\// && $6 !~ /^\/(boot|snap|run|dev|sys|proc|tmp|etc|var\/lib\/docker)(\/|$)/ { print $4, $6 }' \
    | sort -rn | while read -r _ m; do [ -d "$m" ] && { printf '%s' "$m"; break; }; done
}
free_of() { df -P -k "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f GB", $4 / 1048576 }'; }
device_of() { df -P "$1" 2>/dev/null | awk 'NR == 2 { print $1 }'; }
existing() { d=$1; while [ ! -e "$d" ]; do d=$(dirname "$d"); done; printf '%s' "$d"; }

suggest=$(old NV_DATA_HOST)
if [ -z "$suggest" ]; then
  m=$(biggest); [ -n "$m" ] || m=/
  if [ "$m" != / ]; then suggest="${m%/}/nostr-vault"
  elif [ "$mode" = native ]; then suggest=/var/lib/nostr-vault
  else suggest=/srv/nostr-vault
  fi
fi
while :; do
  data=$(ask "Where should your vault live?" "${NV_DATA_HOST:-$suggest}")
  case "$data" in /*) ;; *) warn "Give a full path, starting with /"; [ -n "$TTY" ] || exit 1; continue ;; esac
  data=${data%/}
  at=$(existing "$data")
  say "  $data: $(free_of "$at") free"
  sd=0
  case "$(device_of "$at")" in
    /dev/mmcblk*)
      sd=1
      warn "That's on an SD card. A vault writes all the time: an SD card wears out and is slow. A USB SSD is much better."
      yes_no "Use the SD card anyway?" || { [ -n "$TTY" ] || die "the vault would be on an SD card (set NV_YES=1 to allow it)"; continue; } ;;
  esac
  # A new place starts an empty vault there: the old one's data doesn't follow (Storage › Move vault in the app does).
  was=$(old NV_DATA_HOST) new_ok=0
  if [ -n "$was" ] && [ "$was" != "$data" ] && [ -n "$($SUDO ls -A "$was" 2>/dev/null)" ]; then
    warn "Your vault's data is in $was. Choosing $data starts an empty vault there; $was is left as it is. To move your vault, use Storage › Move vault in the app instead."
    yes_no "Start an empty vault in $data?" || { [ -n "$TTY" ] || die "not switching to an empty vault (set NV_YES=1 to)"; continue; }
    new_ok=1
  fi
  break
done
if [ "$mode" = docker ]; then
  $SUDO mkdir -p "$data"
  $SUDO chown "$VAULT_UID:$VAULT_UID" "$data"
  $SUDO chmod 711 "$data"
fi

# 4. Whose vault it is: only this npub can manage it. The box never holds a secret key.
npub_ok() { printf '%s' "$1" | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$'; }
while :; do
  owner=$(ask "Your npub (the owner: only you can manage this vault)" "${NV_OWNER:-$(old NV_OWNER)}")
  npub_ok "$owner" && break
  warn "That isn't an npub (npub1 and 58 more letters and digits). Copy it from your Nostr app's profile."
  [ -n "$TTY" ] || exit 1
done

if [ "$mode" = native ]; then
  # 5n. The package: from NV_DEB_DIR, or downloaded from the release and checked against its manifest's sha256.
  desktop=${NV_DESKTOP:-}
  if [ -z "$desktop" ]; then
    desktop=0
    for s in /usr/share/xsessions /usr/share/wayland-sessions; do [ -n "$(ls -A "$s" 2>/dev/null)" ] && desktop=1; done
  fi
  debs=$(mktemp -d); trap 'rm -rf "$debs"' EXIT
  get() { # get <file> <out>
    if [ -n "${NV_DEB_DIR:-}" ]; then cp "$NV_DEB_DIR/$1" "$2"
    else curl -fsSL --proto '=https' "$NV_RELEASE/$1" -o "$2"
    fi
  }
  get nostr-vault-linux.json "$debs/m.json" || die "couldn't get the release manifest (nostr-vault-linux.json) from ${NV_DEB_DIR:-$NV_RELEASE}"
  command -v python3 >/dev/null 2>&1 || case $pm in
    apt) { $SUDO apt-get update -q >/dev/null && $SUDO apt-get install -y -q python3 >/dev/null; } ;;
    dnf) $SUDO dnf install -y -q python3 >/dev/null ;;
    pacman) $SUDO pacman -S --noconfirm --needed python >/dev/null ;;
  esac || die "python3 is needed"
  version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$debs/m.json") || die "the manifest isn't valid"
  printf '%s' "$version" | grep -Eq '^[0-9][0-9A-Za-z.+~-]*$' || die "the manifest's version isn't a package version"
  files=$(pkg_name "$version")
  list=""
  for f in $files; do
    sum=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"].get(sys.argv[2],""))' "$debs/m.json" "$f")
    printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' || die "the manifest has no sha256 for $f"
    say "Getting $f…"
    get "$f" "$debs/$f" || die "couldn't get $f"
    [ "$(sha256sum "$debs/$f" | cut -d' ' -f1)" = "$sum" ] || die "$f doesn't match its sha256 in the manifest"
    list="$list $debs/$f"
  done
  chmod 755 "$debs"
  # shellcheck disable=SC2086
  chmod 644 $list
  # A Docker box moving to native: stop it first (its ports are the native vault's), keep its .env as it is.
  if [ "$docker_box" = 1 ] && command -v docker >/dev/null 2>&1; then
    say "Stopping the Docker box (its data stays in $data)…"
    $SUDO docker compose --project-directory "$NV_HOME" -f "$NV_HOME/compose.yml" down >/dev/null 2>&1 || true
  fi
  say "Installing Nostr Vault $version…"
  # One package. Its Recommends (weak deps on dnf, optdepends on pacman) are the window's libraries: wanted on a
  # desktop, left out on a machine with no screen.
  case $pm in
    apt)
      recommends=--no-install-recommends; [ "$desktop" = 1 ] && recommends=--install-recommends
      $SUDO apt-get update -q >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$recommends" $list >/dev/null || die "apt couldn't install the package" ;;
    dnf)
      weak=False; [ "$desktop" = 1 ] && weak=True
      # shellcheck disable=SC2086
      $SUDO dnf install -y -q --setopt=install_weak_deps=$weak $list >/dev/null || die "dnf couldn't install the package" ;;
    pacman)
      # pacman never installs optdepends: on a desktop, ask for the window's libraries by name (the .deb's Recommends).
      if [ "$desktop" = 1 ]; then
        $SUDO pacman -S --noconfirm --needed python python-gobject gtk3 webkit2gtk-4.1 polkit libayatana-appindicator >/dev/null \
          || warn "couldn't install the window's libraries; the vault runs, the window may not"
      fi
      # shellcheck disable=SC2086
      $SUDO pacman -U --noconfirm $list >/dev/null || die "pacman couldn't install the package" ;;
  esac
  port=${NV_PORT:-$(old NV_PORT)}; port=${port:-8080}
  set -- --owner "$owner" --data "$data" --port "$port"
  [ "$sd" = 1 ] && set -- "$@" --sd-ok
  [ "$new_ok" = 1 ] && set -- "$@" --new-ok
  $SUDO nostr-vault-setup "$@" || die "setup didn't finish (journalctl -u nostr-vault shows why)"
  ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  say ""
  say "Your vault is running, and starts by itself when this machine does. On a device on this network, open:"
  [ -n "$ip" ] && say "  http://$ip:$port/"
  say "  http://$(hostname).local:$port/"
  [ "$desktop" = 1 ] && say "On this computer: open Nostr Vault from your apps (its icon also sits in the tray)."
  say "Sign in there with your Nostr account ($owner), then approve this box in My Devices."
  say ""
  say "Data: $data   Settings: sudo nostr-vault-setup --show   Logs: journalctl -fu nostr-vault"
  say "Update: run this installer again (your data, owner and port stay)."
  exit 0
fi

# 5. Ports. The box shares this machine's network (the mesh needs its real LAN address): the vault listens on
# NV_PORT, and on loopback only the engine (3355) and the mesh door (8081). An earlier box of ours holding them is fine.
ours() { $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nostr-vault-linux; }
taken() { command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
port=${NV_PORT:-$(old NV_PORT)}; port=${port:-8080}
if ! ours; then
  for p in 3355 8081; do taken "$p" && die "port $p is in use on this machine, and the vault needs it on its loopback (ss -ltnp shows by what)"; done
  while taken "$port" || [ "$port" = 3355 ] || [ "$port" = 8081 ]; do
    warn "Port $port is taken on this machine."
    [ -n "$TTY" ] || exit 1
    port=$(ask "Port for the vault" "8090")
  done
fi

# 6. Write compose.yml and .env, get the image, start it.
$SUDO mkdir -p "$NV_HOME"
tmp=$(mktemp)
case "$NV_SOURCE" in
  http://*|https://*) curl -fsSL "$NV_SOURCE/compose.yml" -o "$tmp" || die "couldn't download compose.yml from $NV_SOURCE" ;;
  *) cp "$NV_SOURCE/compose.yml" "$tmp" || die "no compose.yml in $NV_SOURCE" ;;
esac
$SUDO install -m 644 "$tmp" "$NV_HOME/compose.yml"
printf 'NV_OWNER=%s\nNV_DATA_HOST=%s\nNV_PORT=%s\nNV_IMAGE=%s\n' "$owner" "$data" "$port" "$NV_IMAGE" >"$tmp"
$SUDO install -m 600 "$tmp" "$NV_HOME/.env"
rm -f "$tmp"

compose() { $SUDO docker compose --project-directory "$NV_HOME" -f "$NV_HOME/compose.yml" "$@"; }
if [ -n "${NV_IMAGE_TAR:-}" ]; then
  say "Loading the image from $NV_IMAGE_TAR…"
  $SUDO docker load -i "$NV_IMAGE_TAR" >/dev/null
else
  say "Getting the Nostr Vault image…"
  compose pull
fi
compose up -d

say "Starting…"
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)" != 000 ]; do
  i=$((i + 1))
  if [ $i -gt 60 ]; then
    $SUDO docker logs --tail 20 nostr-vault-linux >&2 || true
    die "the vault didn't answer on port $port (logs above; again: sudo docker logs nostr-vault-linux)"
  fi
  sleep 1
done

# 7. Where to open it: this machine's addresses on the local network.
ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
say ""
say "Your vault is running. On a device on this network, open:"
[ -n "$ip" ] && say "  http://$ip:$port/"
say "  http://$(hostname).local:$port/"
say "Sign in there with your Nostr account ($owner), then approve this box in My Devices."
say ""
say "Data: $data   Settings: $NV_HOME/.env"
say "Logs: sudo docker logs -f nostr-vault-linux   Stop: sudo docker compose --project-directory $NV_HOME down"
