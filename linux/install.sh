#!/bin/sh
# Install Nostr Vault on a Linux machine (a Raspberry Pi, a mini PC, a home server):
#   curl -fsSL https://raw.githubusercontent.com/btcforplebs/nostr-vault/master/linux/install.sh | sh
# It installs Docker if it's missing, asks where your vault should live and whose it is (your npub), starts the
# vault, and prints the address to open on your local network. Run it again to change either answer or to update:
# the vault's data stays where it is. Nothing here opens a port on your router.
#
# Every question can be answered ahead (for scripts): NV_DATA_HOST=/path NV_OWNER=npub1… NV_YES=1. Also:
#   NV_PORT (8080), NV_IMAGE (the image), NV_HOME (/opt/nostr-vault: compose.yml and .env),
#   NV_SOURCE (where compose.yml comes from: a URL, or a directory), NV_IMAGE_TAR (load the image from a file).
set -eu

NV_HOME=${NV_HOME:-/opt/nostr-vault}
NV_SOURCE=${NV_SOURCE:-https://raw.githubusercontent.com/btcforplebs/nostr-vault/master/linux}
NV_IMAGE=${NV_IMAGE:-ghcr.io/btcforplebs/nostr-vault-linux:latest}
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
  aarch64|arm64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) die "Nostr Vault runs on 64-bit ARM or x86 machines; this one is $(uname -m)" ;;
esac
say "Nostr Vault for Linux ($arch)"

# Values from an earlier install are the defaults this time.
old() { $SUDO cat "$NV_HOME/.env" 2>/dev/null | sed -n "s/^$1=//p" | tail -1; }

# 2. Docker.
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker (from get.docker.com)…"
  command -v curl >/dev/null 2>&1 || die "curl is needed to install Docker"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
if ! $SUDO docker info >/dev/null 2>&1; then
  if [ -d /run/systemd/system ]; then $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  else $SUDO service docker start >/dev/null 2>&1 || true
  fi
  i=0; until $SUDO docker info >/dev/null 2>&1; do i=$((i + 1)); [ $i -gt 30 ] && die "Docker isn't running (try: sudo systemctl start docker)"; sleep 1; done
fi
$SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose is missing (on Debian or Ubuntu: sudo apt-get install docker-compose-plugin)"

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
  if [ "$m" = / ]; then suggest=/srv/nostr-vault; else suggest="${m%/}/nostr-vault"; fi
fi
while :; do
  data=$(ask "Where should your vault live?" "${NV_DATA_HOST:-$suggest}")
  case "$data" in /*) ;; *) warn "Give a full path, starting with /"; [ -n "$TTY" ] || exit 1; continue ;; esac
  data=${data%/}
  at=$(existing "$data")
  say "  $data: $(free_of "$at") free"
  case "$(device_of "$at")" in
    /dev/mmcblk*)
      warn "That's on an SD card. A vault writes all the time: an SD card wears out and is slow. A USB SSD is much better."
      yes_no "Use the SD card anyway?" || { [ -n "$TTY" ] || die "the vault would be on an SD card (set NV_YES=1 to allow it)"; continue; } ;;
  esac
  # A new place starts an empty vault there: the old one's data doesn't follow (Storage › Move vault in the app does).
  was=$(old NV_DATA_HOST)
  if [ -n "$was" ] && [ "$was" != "$data" ] && [ -n "$($SUDO ls -A "$was" 2>/dev/null)" ]; then
    warn "Your vault's data is in $was. Choosing $data starts an empty vault there; $was is left as it is. To move your vault, use Storage › Move vault in the app instead."
    yes_no "Start an empty vault in $data?" || { [ -n "$TTY" ] || die "not switching to an empty vault (set NV_YES=1 to)"; continue; }
  fi
  break
done
$SUDO mkdir -p "$data"
$SUDO chown "$VAULT_UID:$VAULT_UID" "$data"
$SUDO chmod 711 "$data"

# 4. Whose vault it is: only this npub can manage it. The box never holds a secret key.
npub_ok() { printf '%s' "$1" | grep -Eq '^npub1[02-9ac-hj-np-z]{58}$'; }
while :; do
  owner=$(ask "Your npub (the owner: only you can manage this vault)" "${NV_OWNER:-$(old NV_OWNER)}")
  npub_ok "$owner" && break
  warn "That isn't an npub (npub1 and 58 more letters and digits). Copy it from your Nostr app's profile."
  [ -n "$TTY" ] || exit 1
done

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
