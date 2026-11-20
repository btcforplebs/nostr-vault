#!/bin/sh
# Window test: opens the desktop window on a headless display and fails if it draws a flat colour (a blank window).
# Run it on a throwaway machine (a CI runner or a container) with the package installed:
#   window-test.sh <x11|wayland> <setup|vault> <out dir>
#     setup  the vault has no owner yet: the window must draw its setup page
#     vault  the vault is set up and answers on its port: the window must draw the web app, then, after its page's
#            web process is killed, the "stopped drawing" page (and a copy of the window without that handler must
#            draw nothing, which shows this check can tell a blank window from a drawn one); then a page that crashes
#            on every load: the window must stop after two web processes and draw its own GTK crash page (a copy with
#            CRASH_LOOP_S = 0 must keep starting new ones, the control)
#     desk   the vault is set up: signed in as the owner (desk-probe.py, a stub signer), the window's desktop layout must
#            draw the phone's own screens, not the napplets: the box build turns them off (NV_DESK_NAPPLETS, Logen
#            2026-11-20). NV_WT_OWNER: the owner's pubkey hex. NV_WT_DESK_EXPECT=napplets checks the other way.
#     paste  (x11 only) Ctrl+V, pressed with xdotool, into a text field in the window's own web view
#            (paste-probe.py): with an empty clipboard the window must survive, and with text on the clipboard the
#            text must arrive. Where WebKitGTK has the empty-clipboard crash (2.54.0, 2.54.1), a copy of the window
#            without its paste guard must crash on the same empty paste (the control); elsewhere the guard is off.
#            Needs xdotool and xclip. (X11, not Wayland: on headless sway, wtype's letters typed but its Ctrl+V
#            never pasted, with or without the guard, so it couldn't test a paste.)
# The setup stage also prints the user agent the window's web view gives its pages to <out dir>/<mode>-ua.txt
# (ua-probe.py), and fails unless it carries the NostrVaultLinux word the web app's client tag reads.
# x11 runs Xvfb; wayland runs sway on its headless backend (software rendering). Each check is one screenshot in the
# out dir. As root it runs the window as a throwaway user (nvwt); as anyone else, as that user (a Flatpak test).
# NV_WT_CMD is how to start the window (default: nostr-vault-desktop). With NV_WT_CONTROL=0 it skips the copy without
# the handler (a Flatpak can't run a copy of its own script). NV_WT_PY and NV_WT_BIN are the Python and the window's
# script the user-agent probe runs with (defaults: python3 -I and the script NV_WT_CMD runs; a Flatpak's are inside it).
# Needs Xvfb or sway + grim, ImageMagick, dbus-run-session.
set -u
MODE=${1:-}; STAGE=${2:-}; OUT=${3:-}
CMD=${NV_WT_CMD:-nostr-vault-desktop}
MIN_COLOURS=${NV_WT_MIN_COLOURS:-64} # a drawn page has hundreds (anti-aliased text); a blank window has 1 or 2
case "$MODE.$STAGE" in x11.setup|x11.vault|x11.paste|x11.desk|wayland.setup|wayland.vault|wayland.desk) ;; *) echo "usage: $0 <x11|wayland> <setup|vault> <out dir>  (or: x11 paste <out dir>)" >&2; exit 2 ;; esac
[ -n "$OUT" ] || { echo "no out dir" >&2; exit 2; }

if [ "$(id -u)" = 0 ] && [ -z "${NV_WT_INNER:-}" ]; then
  id nvwt >/dev/null 2>&1 || useradd -m nvwt 2>/dev/null || adduser -D nvwt
  mkdir -p "$OUT" && chmod 777 "$OUT"
  cp "$0" /tmp/nvwt-window-test.sh && chmod 755 /tmp/nvwt-window-test.sh
  cp "$(dirname "$0")/ua-probe.py" /tmp/nvwt-ua-probe.py && chmod 644 /tmp/nvwt-ua-probe.py
  cp "$(dirname "$0")/paste-probe.py" /tmp/nvwt-paste-probe.py && chmod 644 /tmp/nvwt-paste-probe.py
  cp "$(dirname "$0")/desk-probe.py" /tmp/nvwt-desk-probe.py && chmod 644 /tmp/nvwt-desk-probe.py
  exec runuser -u nvwt -- env NV_WT_INNER=1 NV_WT_CMD="$CMD" NV_WT_CONTROL="${NV_WT_CONTROL:-1}" NV_WT_VAULT_URL="${NV_WT_VAULT_URL:-}" \
    NV_WT_PROBE=/tmp/nvwt-ua-probe.py NV_WT_PASTE_PROBE=/tmp/nvwt-paste-probe.py NV_WT_DESK_PROBE=/tmp/nvwt-desk-probe.py \
    NV_WT_OWNER="${NV_WT_OWNER:-}" NV_WT_DESK_EXPECT="${NV_WT_DESK_EXPECT:-classic}" NV_WT_PY="${NV_WT_PY:-}" NV_WT_BIN="${NV_WT_BIN:-}" \
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
# crashloop: for 15 s, kill every web process the window starts, as a GPU driver that kills each renderer would.
# Prints how many different web processes it saw.
crashloop() {
  seen=""; end=$(( $(date +%s) + 15 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for p in $(pgrep -u "$(id -u)" -f WebKitWebProcess); do
      case " $seen " in *" $p "*) ;; *) seen="$seen $p" ;; esac
      kill -KILL "$p" 2>/dev/null
    done
    sleep 0.2
  done
  echo $seen | wc -w | tr -d ' '
}
bin=${NV_WT_BIN:-$(command -v "$CMD" 2>/dev/null || true)}

if [ "$STAGE" = setup ]; then
  # The user agent the window's own web view gives its pages: the web app tags posts "on Linux" from it.
  probe=${NV_WT_PROBE:-$(dirname "$0")/ua-probe.py}
  ua=$(dbus-run-session -- ${NV_WT_PY:-python3 -I} - "$bin" <"$probe" 2>"$OUT/$MODE-ua-probe.log" | sed -n 's/^UA //p')
  printf '%s\n' "$ua" >"$OUT/$MODE-ua.txt"
  case " $ua" in
    *" NostrVaultLinux/"*) ok "$MODE: the window's pages see the Linux word in their user agent ($ua)" ;;
    *) no "$MODE: the window's user agent has no NostrVaultLinux/ word: '${ua}'"; tail -20 "$OUT/$MODE-ua-probe.log" ;;
  esac
fi

if [ "$STAGE" = desk ]; then
  # The desktop layout's screens, signed in: FeedScreen and no napplet frame (or, NV_WT_DESK_EXPECT=napplets, the
  # other way round). desk-probe.py fails on its own if the desktop layout never draws, so a sign-in page can't pass.
  echo "${NV_WT_OWNER:-}" | grep -qE '^[0-9a-f]{64}$' || abort "NV_WT_OWNER isn't a pubkey hex"
  url=${NV_WT_VAULT_URL:-http://127.0.0.1:8080/}
  for i in $(seq 1 60); do curl -fsS -o /dev/null "$url" 2>/dev/null && break; sleep 2; done
  dprobe=${NV_WT_DESK_PROBE:-$(dirname "$0")/desk-probe.py}
  d=$(dbus-run-session -- ${NV_WT_PY:-python3 -I} - "$bin" "$NV_WT_OWNER" <"$dprobe" 2>"$OUT/$MODE-desk-probe.log" | sed -n 's/^DESK //p')
  printf '%s\n' "$d" >"$OUT/$MODE-desk.json"
  shot "$OUT/$MODE-desk.png"
  case "${NV_WT_DESK_EXPECT:-classic}.$d" in
    classic.*'"desk": true'*'"napplets": 0,'*'"feed": true'*) ok "$MODE: the desktop layout draws the phone's own screens, no napplets ($d)" ;;
    napplets.*'"desk": true'*'"feed": false'*) case "$d" in *'"napplets": 0,'*) no "$MODE: no napplet frames ($d)" ;; *) ok "$MODE: the desktop layout draws the napplets ($d)" ;; esac ;;
    *) no "$MODE: want the ${NV_WT_DESK_EXPECT:-classic} desktop screens, the window drew: '${d}'"; tail -20 "$OUT/$MODE-desk-probe.log" ;;
  esac
  echo "RESULT $MODE $STAGE pass=$pass fail=$fail"
  [ "$fail" = 0 ]; exit
fi

if [ "$STAGE" = paste ]; then
  command -v xdotool >/dev/null && command -v xclip >/dev/null || abort "no xdotool or xclip"
  pprobe=${NV_WT_PASTE_PROBE:-$(dirname "$0")/paste-probe.py}
  # paste <name> <script> <expect>: one paste-probe run in its own D-Bus session; sets prc (its exit status: 139 is
  # SIGSEGV through sh) and pguard (1 if the window's paste guard is on).
  paste() {
    # The status comes from a shell inside the session: 139 when the probe dies of SIGSEGV.
    dbus-run-session -- sh -c '"$@"; echo "EXIT $?"' sh ${NV_WT_PY:-python3 -I} "$pprobe" "$2" "$3" >"$OUT/$MODE-paste-$1.log" 2>&1
    prc=$(sed -n 's/^EXIT //p' "$OUT/$MODE-paste-$1.log"); prc=${prc:-255}
    pguard=$(sed -n 's/^GUARD //p' "$OUT/$MODE-paste-$1.log")
    pkill -u "$(id -u)" -f WebKitWebProcess 2>/dev/null; sleep 1
  }
  # A new X server: nothing owns the clipboard.
  paste empty "$bin" ""
  wk=$(sed -n 's/^WEBKIT //p' "$OUT/$MODE-paste-empty.log"); echo "WebKitGTK $wk, paste guard ${pguard:-?}"
  if [ "$prc" = 0 ]; then ok "$MODE: Ctrl+V with an empty clipboard: the window survives, the field stays empty"
  else no "$MODE: Ctrl+V with an empty clipboard: the window ended with $prc"; tail -15 "$OUT/$MODE-paste-empty.log"; fi
  if [ "$pguard" = 1 ]; then
    grep -q "kept from WebKit" "$OUT/$MODE-paste-empty.log" && ok "$MODE: the guard kept that paste from WebKit" \
      || no "$MODE: the guard is on but didn't see the paste (no 'kept from WebKit' line)"
  fi
  # With text on the clipboard, the same keys paste it: the guard doesn't stop real pastes (and xdotool's Ctrl+V does
  # reach WebKit's paste, so the empty run above was a real paste).
  printf nv-paste-ok | xclip -quiet -selection clipboard & sleep 1 # owns the clipboard until killed (-quiet: no fork)
  paste text "$bin" "nv-paste-ok"
  pkill -u "$(id -u)" -x xclip; sleep 1
  if [ "$prc" = 0 ]; then ok "$MODE: Ctrl+V with text on the clipboard pastes it"
  else no "$MODE: Ctrl+V with text on the clipboard: exit $prc, field '$(sed -n 's/^VALUE //p' "$OUT/$MODE-paste-text.log")'"; tail -15 "$OUT/$MODE-paste-text.log"; fi
  # The owner leaves (Logen's sequence: copy in an app, quit it, paste): the window saw text on the clipboard, then
  # its owner is killed before Ctrl+V. The guard must have known there was text (HAD True, or this is the empty run
  # again), then know there isn't (AFTER False), and the window must survive the paste.
  printf nv-paste-gone | xclip -quiet -selection clipboard & sleep 1
  export NV_PP_OWNER_LEAVES=1; paste ownerleft "$bin" ""; unset NV_PP_OWNER_LEAVES
  pkill -u "$(id -u)" -x xclip; sleep 1
  had=$(sed -n 's/^HAD //p' "$OUT/$MODE-paste-ownerleft.log"); aft=$(sed -n 's/^AFTER //p' "$OUT/$MODE-paste-ownerleft.log")
  if [ "$pguard" = 1 ]; then
    if [ "$had" = True ] && [ "$aft" = False ] && [ "$prc" = 0 ]; then ok "$MODE: owner left: the guard saw text, then none, and the window survived the paste"
    else no "$MODE: owner left: before '$had', after '$aft' (want True, False), exit $prc"; tail -15 "$OUT/$MODE-paste-ownerleft.log"; fi
  elif [ "$prc" = 0 ]; then ok "$MODE: owner left: the window survived the paste (no guard on this WebKit)"
  else no "$MODE: owner left: exit $prc"; fi
  if [ "$pguard" = 1 ]; then
    # Control: this WebKit has the bug, so the window without its guard must crash on the same empty paste, or the
    # "survives" above proves nothing.
    sed 's/^PASTE_GUARD = .*/PASTE_GUARD = False/' "$bin" >"$RUN/no-guard"
    if cmp -s "$bin" "$RUN/no-guard"; then no "control: couldn't turn the paste guard off in $bin"; else
      pgrep -u "$(id -u)" -x xclip >/dev/null && abort "xclip still owns the clipboard: the control wouldn't be empty"
      paste control "$RUN/no-guard" ""
      if [ "$prc" -ge 128 ]; then ok "control: without the guard, WebKitGTK $wk crashes on that paste (exit $prc)"
      else no "control: without the guard the empty paste didn't crash (exit $prc), so the check above can't tell"; fi
    fi
  else
    case "$wk" in 2.54.0|2.54.1) no "$MODE: WebKitGTK $wk has the empty-clipboard crash but the guard is off" ;;
      *) echo "NOTE: WebKitGTK $wk doesn't have the empty-clipboard crash: the guard is off and there is no control" ;; esac
  fi
  grep -q '^KEY ' "$OUT/$MODE-paste-text.log" || echo "NOTE: the window got no key at all in the text run"
  echo "RESULT $MODE $STAGE pass=$pass fail=$fail"
  [ "$fail" = 0 ]; exit
fi

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
    stop
  fi
  # A page that crashes on every load: the window must give up after the crash page's own web process dies, not
  # start one after another, and must still draw something (its GTK crash page, which needs no web process).
  start loop $CMD
  sleep 8
  drawn "$OUT/$MODE-$STAGE-4-loop-vault.png" "$MODE: the window draws the web app again" >/dev/null || true
  n=$(crashloop)
  if [ "$n" -ge 1 ] && [ "$n" -le 3 ]; then ok "$MODE: a page that crashes every time stops after $n web processes"
  else no "$MODE: a page that crashes every time started $n web processes in 15 s (want 1 to 3)"; fi
  sleep 6
  w=$(webproc)
  if [ -z "$w" ]; then ok "$MODE: after it stops, no web process is started again"; else no "$MODE: a web process ($w) started after the stop"; fi
  drawn "$OUT/$MODE-$STAGE-5-loop-stopped.png" "$MODE: the window draws its own crash page" "$OUT/$MODE-$STAGE-4-loop-vault.png"
  grep -q "not loading another page" "$OUT/$MODE-$STAGE-loop.log" && ok "$MODE: the window says why it stopped" \
    || no "$MODE: no 'not loading another page' line in the window's log"
  stop
  if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
    # Control: the same window with no backoff (CRASH_LOOP_S = 0) keeps starting web processes under the same
    # killing, or "stops after n" above proves nothing.
    sed 's/^CRASH_LOOP_S = 5$/CRASH_LOOP_S = 0/' "$bin" >"$RUN/no-backoff"
    if cmp -s "$bin" "$RUN/no-backoff"; then no "control: couldn't turn the backoff off in $bin"; else
      start control-loop python3 -I "$RUN/no-backoff"
      sleep 8
      drawn "$OUT/$MODE-$STAGE-6-control-loop-vault.png" "control: the no-backoff copy draws the web app" >/dev/null || true
      n=$(crashloop)
      if [ "$n" -ge 5 ]; then ok "control: with no backoff the same killing saw $n web processes in 15 s"
      else no "control: with no backoff only $n web processes in 15 s, so the backoff check can't tell"; fi
    fi
  fi
fi
stop
if [ "$fail" != 0 ]; then echo "-- window log:"; tail -40 "$OUT/$MODE-$STAGE-window.log" 2>/dev/null; fi
echo "RESULT $MODE $STAGE pass=$pass fail=$fail"
[ "$fail" = 0 ]
