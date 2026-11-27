# window-test.sh's "spin" stage (sourced by it; uses its start, stop, shot, colours, drawn, ok, no, webproc): a page
# whose JavaScript never answers because the copy of the web app in WebKit's cache spins (Guy's window, 2026-11-27:
# its web process at 100% CPU and no system calls). spin-server.py is the vault: its first app.js saves a sign-in
# and then loops forever, cached for a year; any later one draws. nv_paint.py + nv_heal.py must:
#   1. notice, move WebKit's cache aside (kept as a .bak) and start over in the same drawing mode, and draw the fresh
#      web app, with the sign-in it saved still there (localStorage is not touched). A copy without the fresh cache
#      (the control) keeps loading the cached copy that spins.
#   2. end, on its next start, WebKit processes of ours that no window owns, with their whole tree (a bwrap and the
#      unmarked process in it; a real web process left by a window that was killed), and leave another app's alone.
#   3. (Wayland) not judge while the window's frame clock doesn't tick: the screen powered off (sway's output power
#      off, as DPMS) is not a page that never answers. A copy without that gate (the control) starts over meanwhile.
# The root half of window-test.sh points vault.env at the stand-in (NV_PORT) and puts it back after.
G=15
PORT=${NV_WT_SPIN_PORT:-18471}
RJ=$HOME/.config/nostr-vault-desktop/renderer.json
CACHE=$HOME/.cache/nostr-vault-desktop
DATA=$HOME/.local/share/nostr-vault-desktop
SERVER=${NV_WT_SPIN_SERVER:-$(dirname "$0")/spin-server.py}
SHARE_DIR=${NV_DESKTOP_SHARE:-/usr/share/nostr-vault/desktop}
SPID=""
fresh() { rm -rf "$RJ" "$CACHE" "$CACHE".bak-* "$DATA"; }
serve() { : >"$OUT/$MODE-spin-$1-requests.log"; python3 -I "$SERVER" "$PORT" "$OUT/$MODE-spin-$1-requests.log" "$2" & SPID=$!; sleep 1; }
unserve() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; SPID=""; }
fetches() { grep -c '^GET /app.js' "$1" 2>/dev/null; }
waitlog() { for i in $(seq 1 "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 1; done; return 1; }
# share <name> <sed script>: a copy of the window's Python files with one change, run with NV_DESKTOP_SHARE.
share() { rm -rf "$RUN/share-$1"; cp -r "$SHARE_DIR" "$RUN/share-$1"; sed -i "$2" "$RUN/share-$1/nv_paint.py"
  ! cmp -s "$SHARE_DIR/nv_paint.py" "$RUN/share-$1/nv_paint.py"; }

# 1. The cached copy spins: a fresh cache, the same mode, and the sign-in kept.
fresh; tok="keep-$$-$(date +%s)"
serve heal "$tok"
start heal env NV_PAINT_GIVE_UP_S=$G $CMD
L="$OUT/$MODE-spin-heal.log"; R="$OUT/$MODE-spin-heal-requests.log"
if waitlog "$L" "moved WebKit's cache aside" $((G + 40)); then
  ok "$MODE: a page that spins is noticed: $(grep -o "moved WebKit's cache aside ([^)]*)" "$L" | head -1)"
else no "$MODE: the window never moved its cache aside for a page that spins"; tail -20 "$L"; fi
drawn "$OUT/$MODE-spin-1-healed.png" "$MODE: then the window draws the fresh web app"
if waitlog "$R" "^GET /saw" 20 && grep -q "^GET /saw?.*$tok" "$R"; then
  ok "$MODE: the fresh copy finds the sign-in the spinning one saved (localStorage nv-session kept)"
else no "$MODE: the fresh copy didn't find the saved sign-in: $(grep '^GET /saw' "$R" | head -1)"; fi
n=$(fetches "$R")
[ "$n" = 2 ] && ok "$MODE: app.js asked for twice: the cached copy, then once after the cache moved" \
  || no "$MODE: app.js asked for $n times (want 2)"
b=$(ls -d "$CACHE".bak-* 2>/dev/null | head -1)
if [ -n "$b" ] && [ -n "$(ls -A "$b" 2>/dev/null)" ] && [ -f "$CACHE/window.log" ]; then
  ok "$MODE: the old cache is kept ($(basename "$b"): $(ls "$b" | tr '\n' ' ')) and window.log stayed"
else no "$MODE: no kept cache ('$b') or window.log moved"; fi
if [ -d "$DATA/localstorage" ] && [ ! -e "$b/localstorage" ]; then ok "$MODE: localStorage stayed in place ($DATA/localstorage)"
else no "$MODE: localStorage isn't where it was: $(ls "$DATA" 2>/dev/null | tr '\n' ' ')"; fi
grep -q "trying the window again with mode" "$L" && no "$MODE: it went down the drawing ladder too" \
  || ok "$MODE: it stayed in its drawing mode (a spin is not a drawing problem)"
waitlog "$L" "it draws with a fresh WebKit cache" 20 && ok "$MODE: and says the fresh cache fixed it" \
  || no "$MODE: the window never passed its check after the fresh cache"
stop; unserve

# 1b. Control: the same page, without the fresh cache: the cached copy spins in every mode.
if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
  if ! share noheal 's/if not self.js_ok and nv_heal.may_reset(st):/if False:/'; then no "control: couldn't take the fresh cache out"; else
    fresh; serve noheal "$tok"
    start noheal env NV_DESKTOP_SHARE="$RUN/share-noheal" NV_PAINT_GIVE_UP_S=$G $CMD
    L="$OUT/$MODE-spin-noheal.log"; R="$OUT/$MODE-spin-noheal-requests.log"
    waitlog "$L" "trying the window again with mode" $((G + 40))
    sleep $((G + 10))
    n=$(fetches "$R")
    if [ "$n" = 1 ] && ! grep -q "^GET /saw" "$R" && grep -q "trying the window again with mode" "$L"; then
      ok "control: without the fresh cache every new try loads the cached copy that spins (app.js asked for once; $(grep -c 'trying the window again with mode' "$L") new drawing modes, none drew it)"
    else no "control: without the fresh cache app.js was asked for $n times, /saw $(grep -c '^GET /saw' "$R"): this test can't tell"; fi
    stop; unserve
  fi
fi

# 2. Stray WebKit processes: ours with no window (a fake bwrap with an unmarked process inside, a real web process
# whose window was killed) end when the window starts; another app's (no NV_DESKTOP_RENDERER) stays.
fresh; serve reap "$tok"
# A real one first: a window on the spinning page (no check within 600 s), killed: its web process spins on, alone.
start orphan env NV_PAINT_GIVE_UP_S=600 $CMD
w=""; for i in $(seq 1 20); do w=$(webproc); [ -n "$w" ] && break; sleep 1; done
sleep 3
wp=$(pgrep -u "$(id -u)" -f '(^|/)python3(\.[0-9]+)? -I .*nostr-vault-desktop' | head -1)
[ -n "$wp" ] && kill -KILL "$wp"
cp /bin/sleep "$RUN/WebKitWebProcess"; cp /bin/sh "$RUN/bwrap"
env NV_DESKTOP_RENDERER=dmabuf setsid "$RUN/bwrap" -c "echo \$\$ >$RUN/b.pid; env -u NV_DESKTOP_RENDERER $RUN/WebKitWebProcess 600 & echo \$! >$RUN/i.pid; wait" </dev/null >/dev/null 2>&1 &
env -u NV_DESKTOP_RENDERER setsid "$RUN/WebKitWebProcess" 601 </dev/null >/dev/null 2>&1 &
echo $! >"$RUN/o.pid"
sleep 2
b=$(cat "$RUN/b.pid" 2>/dev/null); i=$(cat "$RUN/i.pid" 2>/dev/null); o=$(cat "$RUN/o.pid")
alive() { [ -n "$1" ] && [ -d "/proc/$1" ] && [ "$(sed 's/.*) \(.\).*/\1/' "/proc/$1/stat" 2>/dev/null)" != Z ]; }
if alive "$b" && alive "$i" && alive "$o" && alive "$w" && ! alive "$wp"; then
  ok "strays: before the window starts: a bwrap $b with $i inside, a web process $w whose window $wp was killed, another app's $o"
else no "strays: couldn't set them up (bwrap '$b' inner '$i' orphan '$w' window '$wp' other '$o')"; fi
start reap $CMD
L="$OUT/$MODE-spin-reap.log"
waitlog "$L" "stray WebKit process" 15
sleep 3
alive "$b" || alive "$i" || alive "$w" && no "strays: still running after the window started: $(for p in $b $i $w; do alive $p && echo $p; done | tr '\n' ' ')" \
  || ok "strays: the window ended them, the whole tree ($(grep -o 'ending .*' "$L" | head -1))"
alive "$o" && ok "strays: another app's WebKit process ($o) is left alone" || no "strays: another app's WebKit process was ended"
drawn "$OUT/$MODE-spin-2-reap.png" "$MODE: and the window draws" >/dev/null || true
stop; unserve; kill "$o" 2>/dev/null

# 2b. A running window's WebKit is never a stray (Tron, PR 2622 review): not when the window was started by its
# shebang (named "nostr-vault-des", not python), not when a second launch hands off to it, not when another window
# starts on its own D-Bus. The control (owner by command name, as before) ends it.
live() { # live <name> <share or ''>: a window on the spinning page; sets wp (window) and w1 (its web process)
  fresh; serve "live-$1" "$tok"
  if [ -n "$2" ]; then start "live-$1" env NV_DESKTOP_SHARE="$2" NV_PAINT_GIVE_UP_S=600 $CMD
  else start "live-$1" env NV_PAINT_GIVE_UP_S=600 $CMD; fi
  w1=""; for i in $(seq 1 20); do w1=$(webproc); [ -n "$w1" ] && break; sleep 1; done
  sleep 3; wp=""; p=$w1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'nostr-vault-desktop' && { wp=$p; break; }
    p=$(sed 's/.*) . \([0-9]*\).*/\1/' "/proc/$p/stat" 2>/dev/null)
  done
}
live owner ""
if [ -n "$w1" ] && [ -n "$wp" ]; then
  ok "live window $wp ($(cat /proc/$wp/comm)) with its web process $w1"
  bus=$(tr '\0' '\n' <"/proc/$wp/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
  env DBUS_SESSION_BUS_ADDRESS="$bus" timeout 20 $CMD --open feed >"$OUT/$MODE-spin-handoff.log" 2>&1; r=$?
  sleep 3
  [ "$r" = 0 ] && alive "$w1" && ok "a second launch (--open feed) hands off and exits; the window's web process lives on" \
    || no "a second launch (exit $r): the window's web process $w1 $(alive "$w1" && echo lives || echo was ended)"
  start other $CMD
  waitlog "$OUT/$MODE-spin-other.log" "drawing mode" 20; sleep 5
  alive "$w1" && ok "another window starting on its own D-Bus leaves the running window's web process alone" \
    || no "another window starting ended the running window's web process ($(grep -o 'ending .*' "$OUT/$MODE-spin-other.log" | head -1))"
else no "live window: couldn't find it (window '$wp', web process '$w1')"; fi
stop; unserve
if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
  rm -rf "$RUN/share-bycomm"; cp -r "$SHARE_DIR" "$RUN/share-bycomm"
  sed -i 's/if _window(p):/if procs[p][1].startswith("python") and _marked(p):/' "$RUN/share-bycomm/nv_heal.py"
  if cmp -s "$SHARE_DIR/nv_heal.py" "$RUN/share-bycomm/nv_heal.py"; then no "control: couldn't put the by-name owner test back"
  else
    live bycomm ""
    start other-bycomm env NV_DESKTOP_SHARE="$RUN/share-bycomm" $CMD
    waitlog "$OUT/$MODE-spin-other-bycomm.log" "drawing mode" 20; sleep 5
    alive "$w1" && no "control: with the by-name owner test the running window's web process lived too: this check can't tell" \
      || ok "control: with the by-name owner test (as before) another window's start ended the running window's web process"
    stop; unserve
  fi
fi

# 2c. What the window opens (a link, the logs) gets none of its variables: another app's WebKit started from a link
# must never carry NV_DESKTOP_RENDERER (it would be "ours" once our window had gone).
mkdir -p "$HOME/.local/share/applications" "$HOME/.config"
printf '#!/bin/sh\nenv >"%s/link-env.txt"\n' "$RUN" >"$RUN/envdump"; chmod 755 "$RUN/envdump"
printf '[Desktop Entry]\nType=Application\nName=nvwt env\nExec=%s %%u\nMimeType=x-scheme-handler/nvwtenv;\n' "$RUN/envdump" \
  >"$HOME/.local/share/applications/nvwt-env.desktop"
printf '[Default Applications]\nx-scheme-handler/nvwtenv=nvwt-env.desktop\n' >"$HOME/.config/mimeapps.list"
linkenv() { # linkenv <python>: runs it with our variables set; prints how many of them the handler got
  rm -f "$RUN/link-env.txt"
  env NV_DESKTOP_RENDERER=dmabuf NV_DESKTOP_TRIED=default WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    dbus-run-session -- python3 -I -c "import sys; sys.path.insert(0, '$SHARE_DIR'); import nv_heal; from gi.repository import Gio; $1" \
    >>"$OUT/$MODE-spin-linkenv.log" 2>&1
  for i in $(seq 1 10); do [ -s "$RUN/link-env.txt" ] && break; sleep 0.5; done
  [ -s "$RUN/link-env.txt" ] || { echo none; return; }
  grep -c -E '^(NV_DESKTOP_RENDERER|NV_DESKTOP_TRIED|WEBKIT_DISABLE_DMABUF_RENDERER|WEBKIT_DISABLE_COMPOSITING_MODE)=' "$RUN/link-env.txt"
}
n=$(linkenv "nv_heal.launch_uri('nvwtenv:x')")
[ "$n" = 0 ] && ok "a link the window opens starts its app without our variables" || no "a link the window opens: its app got $n of our variables"
[ "${NV_WT_CONTROL:-1}" = 1 ] && { n=$(linkenv "Gio.AppInfo.launch_default_for_uri('nvwtenv:x', None)")
  [ "$n" = 4 ] && ok "control: launched as before (no launch context) the same app gets all 4" || no "control: launched as before it got '$n' of 4: this check can't tell"; }
n=$(linkenv "import subprocess; subprocess.run(['$RUN/envdump'], env=nv_heal.child_env())")
[ "$n" = 0 ] && ok "the logs terminal (child_env) starts without our variables" || no "child_env: the process got $n of our variables"
rm -f "$HOME/.local/share/applications/nvwt-env.desktop" "$HOME/.config/mimeapps.list"

# 3. The frame clock (Wayland: sway can power its output off; Xvfb has no such thing): no judgement while it stops.
if [ "$MODE" = wayland ]; then
  export SWAYSOCK=$(ls "$RUN"/sway-ipc.*.sock 2>/dev/null | head -1)
  screen() { swaymsg output '*' power "$1" >/dev/null 2>&1 || swaymsg output '*' dpms "$1" >/dev/null 2>&1; }
  # dark <name> <share or ''>: the window on the spinning page with the screen off for 2G+10 s -> 0 if it judged.
  dark() {
    fresh; serve "dark-$1" "$tok"
    if [ -n "$2" ]; then start "dark-$1" env NV_DESKTOP_SHARE="$2" NV_PAINT_GIVE_UP_S=$G $CMD
    else start "dark-$1" env NV_PAINT_GIVE_UP_S=$G $CMD; fi
    sleep 1; screen off
    sleep $((2 * G + 10))
    grep -q "didn't draw in mode" "$OUT/$MODE-spin-dark-$1.log"; r=$?
    screen on
    return $r
  }
  if dark gate ""; then no "frame clock: with the screen off the window judged its page anyway"
  elif grep -q "frame clock isn't ticking" "$OUT/$MODE-spin-dark-gate.log"; then
    ok "frame clock: with the screen off for $((2 * G + 10)) s the window waits ('frame clock isn't ticking')"
  else no "frame clock: the screen went off but the window never said its frame clock stopped"; fi
  waitlog "$OUT/$MODE-spin-dark-gate.log" "didn't draw in mode" $((G + 20)) \
    && ok "frame clock: once the screen is on again it judges (and heals) the page" \
    || no "frame clock: with the screen on again it never judged the page"
  stop; unserve
  if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
    if ! share nogate 's/stalled = n is not None and self._frames/stalled = False and self._frames/'; then no "control: couldn't take the gate out"
    elif dark nogate "$RUN/share-nogate"; then ok "control: without the gate the same window judged its page with the screen off"
    else no "control: without the gate the window didn't judge either, so this check can't tell"; fi
    stop; unserve
  fi
fi
fresh
