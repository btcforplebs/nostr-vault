#!/bin/sh
# Window test: opens the desktop window on a headless display and fails if it draws a flat colour (a blank window).
# Run it on a throwaway machine (a CI runner or a container) with the package installed:
#   window-test.sh <x11|wayland> <setup|vault> <out dir>
#     setup  the vault has no owner yet: the window must draw its setup page
#     vault  the vault is set up and answers on its port: the window must draw the web app, then, after its page's
#            web process is killed, the "stopped drawing" page (and a copy of the window without that handler must
#            draw nothing, which shows this check can tell a blank window from a drawn one)
# x11 runs Xvfb; wayland runs sway on its headless backend (software rendering). Each check is one screenshot in the
# out dir. As root it runs the window as a throwaway user (nvwt); as anyone else, as that user (a Flatpak test).
# NV_WT_CMD is how to start the window (default: nostr-vault-desktop). With NV_WT_CONTROL=0 it skips the copy without
# the handler (a Flatpak can't run a copy of its own script). Needs Xvfb or sway + grim, ImageMagick, dbus-run-session.
set -u
MODE=${1:-}; STAGE=${2:-}; OUT=${3:-}
CMD=${NV_WT_CMD:-nostr-vault-desktop}
MIN_COLOURS=${NV_WT_MIN_COLOURS:-64} # a drawn page has hundreds (anti-aliased text); a blank window has 1 or 2
case "$MODE.$STAGE" in x11.setup|x11.vault|wayland.setup|wayland.vault) ;; *) echo "usage: $0 <x11|wayland> <setup|vault> <out dir>" >&2; exit 2 ;; esac
[ -n "$OUT" ] || { echo "no out dir" >&2; exit 2; }

if [ "$(id -u)" = 0 ] && [ -z "${NV_WT_INNER:-}" ]; then
  id nvwt >/dev/null 2>&1 || useradd -m nvwt 2>/dev/null || adduser -D nvwt
  mkdir -p "$OUT" && chmod 777 "$OUT"
  cp "$0" /tmp/nvwt-window-test.sh && chmod 755 /tmp/nvwt-window-test.sh
  exec runuser -u nvwt -- env NV_WT_INNER=1 NV_WT_CMD="$CMD" NV_WT_CONTROL="${NV_WT_CONTROL:-1}" NV_WT_VAULT_URL="${NV_WT_VAULT_URL:-}" \
    NV_WT_MIN_COLOURS="$MIN_COLOURS" PATH="$PATH" HOME=/home/nvwt sh /tmp/nvwt-window-test.sh "$MODE" "$STAGE" "$OUT"
fi
mkdir -p "$OUT"

pass=0; fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
no() { echo "FAIL: $*"; fail=$((fail+1)); }
abort() { echo "ABORT: $*"; echo "RESULT $MODE $STAGE pass=$pass fail=$fail (aborted)"; cleanup; exit 1; }
im() { if command -v magick >/dev/null; then magick "$@"; else "$@"; fi; } # ImageMagick 7 or 6

RUN=$(mktemp -d /tmp/nvwt-run.XXXXXX); chmod 700 "$RUN"
export XDG_RUNTIME_DIR="$RUN"
DPID=""; APID=""
cleanup() {
  [ -n "$APID" ] && kill "$APID" 2>/dev/null
  pkill -u "$(id -u)" -f WebKitWebProcess 2>/dev/null
  pkill -u "$(id -u)" -f nostr-vault-desktop 2>/dev/null
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
  sleep 1
}
trap cleanup EXIT

# ---- the display
if [ "$MODE" = x11 ]; then
  command -v Xvfb >/dev/null || abort "no Xvfb"
  Xvfb :77 -screen 0 1400x1000x24 -nolisten tcp >"$OUT/$MODE-$STAGE-display.log" 2>&1 & DPID=$!
  export DISPLAY=:77 GDK_BACKEND=x11; unset WAYLAND_DISPLAY
  for i in $(seq 1 20); do [ -e /tmp/.X11-unix/X77 ] && break; sleep 0.5; done
  [ -e /tmp/.X11-unix/X77 ] || abort "Xvfb didn't start"
  shot() { im import -window root "$1" 2>/dev/null; }
else
  command -v sway >/dev/null && command -v grim >/dev/null || abort "no sway or grim"
  # No bar, no borders, a black background: a blank window is then one flat colour, as on X11.
  printf 'xwayland disable\noutput * resolution 1400x1000 bg #000000 solid_color\ndefault_border none\ndefault_floating_border none\n' >"$RUN/sway.cfg"
  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$RUN/sway.cfg" >"$OUT/$MODE-$STAGE-display.log" 2>&1 & DPID=$!
  for i in $(seq 1 30); do s=$(ls "$RUN" | grep -E '^wayland-[0-9]+$' | head -1); [ -n "$s" ] && break; sleep 0.5; done
  [ -n "${s:-}" ] || { tail -20 "$OUT/$MODE-$STAGE-display.log"; abort "sway didn't start"; }
  export WAYLAND_DISPLAY=$s GDK_BACKEND=wayland; unset DISPLAY
  shot() { grim "$1" 2>/dev/null; }
fi
colours() { im identify -format '%k' "$1" 2>/dev/null || echo 0; }
pixels() { im convert "$1" rgba:- 2>/dev/null | cksum; } # the same pixels: the same picture

# The check's own control: the empty display is a flat colour, and the check must say so.
shot "$OUT/$MODE-$STAGE-0-empty.png" || abort "can't take a screenshot"
c=$(colours "$OUT/$MODE-$STAGE-0-empty.png")
if [ "$c" -lt "$MIN_COLOURS" ]; then ok "control: the empty display is flat ($c colours)"; else abort "the empty display has $c colours: this check can't see a blank window"; fi

# start <name> <command…>: the window, in its own D-Bus session (so it is its own app, not a message to another one).
start() { n=$1; shift; dbus-run-session -- "$@" >"$OUT/$MODE-$STAGE-$n.log" 2>&1 & APID=$!; }
stop() { kill "$APID" 2>/dev/null; pkill -u "$(id -u)" -f WebKitWebProcess 2>/dev/null; pkill -u "$(id -u)" -f nostr-vault-desktop 2>/dev/null; APID=""; sleep 2; }
# drawn <png> <what> [<png before>]: up to 90 s for the window to draw something that isn't flat (and, given a
# picture from before, isn't that picture: a dead view can keep showing its last frame).
drawn() {
  for i in $(seq 1 30); do
    sleep 3; shot "$1"; c=$(colours "$1")
    if [ "$c" -ge "$MIN_COLOURS" ] && { [ -z "${3:-}" ] || [ "$(pixels "$1")" != "$(pixels "$3")" ]; }; then
      ok "$2 ($c colours, after $((i*3)) s)"; return 0
    fi
  done
  no "$2: still flat or unchanged after 90 s ($c colours)"; return 1
}
webproc() { pgrep -u "$(id -u)" -f WebKitWebProcess | head -1; }

start window $CMD
if [ "$STAGE" = setup ]; then
  drawn "$OUT/$MODE-$STAGE-1-setup.png" "$MODE: the window draws the setup page"
else
  # The vault must answer first (a Flatpak's window starts its own), then the window leaves its waiting page for the
  # web app on its next 5 s check.
  url=${NV_WT_VAULT_URL:-http://127.0.0.1:8080/}
  for i in $(seq 1 60); do curl -fsS -o /dev/null "$url" 2>/dev/null && break; sleep 2; done
  curl -fsS -o /dev/null "$url" 2>/dev/null || no "the vault never answered on $url"
  sleep 8
  drawn "$OUT/$MODE-$STAGE-1-vault.png" "$MODE: the window draws the vault's web app"
  wp=$(webproc)
  if [ -n "$wp" ] && tr '\0' '\n' <"/proc/$wp/environ" 2>/dev/null | grep -qx 'WEBKIT_DISABLE_DMABUF_RENDERER=1'; then
    ok "$MODE: the page's web process runs with the DMA-BUF renderer off"
  else
    no "$MODE: the page's web process (${wp:-none}) doesn't have WEBKIT_DISABLE_DMABUF_RENDERER=1"
  fi
  pkill -KILL -u "$(id -u)" -f WebKitWebProcess
  drawn "$OUT/$MODE-$STAGE-2-crashed.png" "$MODE: after its web process is killed, the window says it stopped drawing" "$OUT/$MODE-$STAGE-1-vault.png"
  stop
  if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
    # Control: the same window without the handler. Its killed page must leave a flat window, or "not flat" above
    # proves nothing.
    bin=$(command -v "$CMD")
    sed '/"web-process-terminated"/d' "$bin" >"$RUN/no-handler"
    if cmp -s "$bin" "$RUN/no-handler"; then no "control: couldn't remove the handler from $bin"; else
      start control python3 -I "$RUN/no-handler"
      drawn "$OUT/$MODE-$STAGE-3-control-vault.png" "control: the copy draws the web app" >/dev/null || true
      pkill -KILL -u "$(id -u)" -f WebKitWebProcess
      k="$OUT/$MODE-$STAGE-3-control-killed.png"; sleep 12; shot "$k"; c=$(colours "$k")
      if [ "$c" -lt "$MIN_COLOURS" ]; then ok "control: without the handler a killed page leaves a flat window ($c colours)"
      elif [ "$(pixels "$k")" = "$(pixels "$OUT/$MODE-$STAGE-3-control-vault.png")" ]; then
        ok "control: without the handler a killed page leaves its last frame, unchanged"
      else no "control: without the handler the window changed after the kill ($c colours), so the check above can't tell"; fi
    fi
  fi
fi
stop
if [ "$fail" != 0 ]; then echo "-- window log:"; tail -40 "$OUT/$MODE-$STAGE-window.log" 2>/dev/null; fi
echo "RESULT $MODE $STAGE pass=$pass fail=$fail"
[ "$fail" = 0 ]
