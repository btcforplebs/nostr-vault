# window-test.sh's "blank" stage (sourced by it; uses its start, stop, shot, colours, drawn, ok, no, webproc, wenv):
# a window whose page never draws, as on a graphics stack where WebKit hangs or shows nothing (beta 9's grey window
# on a Radeon 780M under Wayland, 2026-11-25). The window's web processes are stopped (SIGSTOP) as they start, so
# they never draw a frame or answer JavaScript: a hung renderer, for real, not a faked check. nv_paint.py must notice
# and start the window over in its next drawing mode, remember the one that drew, and when none draws show its GTK
# "open in browser" page and remember that. A copy of the window without the check (the control) must stay blank.
# Then the update signal the .deb's postinst sends (SIGUSR2): the window starts over in place and draws again.
# Runs before setup (the setup page is the window's page). NV_PAINT_GIVE_UP_S makes each try 15 s, not 45.
G=15
RJ=$HOME/.config/nostr-vault-desktop/renderer.json
POSTINST_PATTERN='^/usr/bin/python3(\.[0-9]+)? -I /usr/bin/nostr-vault-desktop( |$)' # as linux/native/debian/postinst
# freeze <log> <regex or ''> <s>: stop every web process the window starts, for up to s seconds or until the log
# says regex (true then; with no regex, true after s seconds).
freeze() {
  end=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    [ -n "$2" ] && grep -q "$2" "$1" 2>/dev/null && return 0
    pkill -STOP -u "$(id -u)" -f WebKitWebProcess 2>/dev/null
    sleep 0.1
  done
  [ -z "$2" ]
}
thaw() { pkill -KILL -u "$(id -u)" -f WebKitWebProcess 2>/dev/null; sleep 1; }
works() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$RJ" "$1" 2>/dev/null; }

# 1. The first mode never draws: the window starts over in the next one, which draws, and remembers it.
rm -f "$RJ"
start retry env NV_PAINT_GIVE_UP_S=$G $CMD
L="$OUT/$MODE-blank-retry.log"
if freeze "$L" "trying the window again with mode" $((G + 30)); then
  m1=$(sed -n "s/.*didn't draw in mode \([a-z-]*\) .*/\1/p" "$L" | head -1)
  m2=$(sed -n 's/.*trying the window again with mode \([a-z-]*\).*/\1/p' "$L" | head -1)
  ok "$MODE: a page that never draws in mode $m1 is noticed; the window starts over in mode $m2"
else
  m2=""; no "$MODE: the window never noticed its page doesn't draw"; tail -20 "$L"
fi
drawn "$OUT/$MODE-blank-1-retry.png" "$MODE: started over in mode $m2, the window draws its page"
for i in $(seq 1 20); do grep -q "remembered drawing mode $m2" "$L" && break; sleep 1; done
if [ -n "$m2" ] && grep -q "remembered drawing mode $m2" "$L" && [ "$(works works)" = "$m2" ]; then
  ok "$MODE: mode $m2 is remembered ($RJ)"
else no "$MODE: mode '$m2' not remembered: $(cat "$RJ" 2>/dev/null)"; fi
stop; thaw

# 2. The next start draws in the remembered mode straight away.
start again $CMD
sleep 10
wp=$(webproc); wm=$(wenv "$wp" NV_DESKTOP_RENDERER)
if [ -n "$m2" ] && [ "$wm" = "$m2" ] && ! grep -q "trying the window again" "$OUT/$MODE-blank-again.log"; then
  ok "$MODE: the next start draws in the remembered mode $m2 at once"
else no "$MODE: the next start's web process is in mode '$wm' (want '$m2')"; tail -10 "$OUT/$MODE-blank-again.log"; fi
stop

# 3. No mode draws: after every one is tried, the window's GTK page opens the vault in the browser; remembered.
rm -f "$RJ"
start allfail env NV_PAINT_GIVE_UP_S=$G $CMD
L="$OUT/$MODE-blank-allfail.log"
if freeze "$L" "in any drawing mode" $((3 * (G + 15))); then
  n=$(grep -c "trying the window again with mode" "$L")
  if [ "$n" = 2 ]; then ok "$MODE: no mode draws: the window tried all three, then gave up"
  else no "$MODE: no mode draws: it started over $n times (want 2)"; fi
else no "$MODE: no mode draws, and the window never gave up"; tail -20 "$L"; fi
thaw
drawn "$OUT/$MODE-blank-2-browser.png" "$MODE: then it draws its own 'open in browser' page (GTK, no web process)"
if [ -n "$(works failed)" ]; then ok "$MODE: remembered that nothing draws with WebKitGTK $(works failed)"
else no "$MODE: the failure isn't remembered: $(cat "$RJ" 2>/dev/null)"; fi
stop
start remembered $CMD
sleep 8
grep -q "last time: showing the browser page" "$OUT/$MODE-blank-remembered.log" \
  && ok "$MODE: the next start shows the browser page at once" \
  || { no "$MODE: the next start didn't go straight to the browser page"; tail -10 "$OUT/$MODE-blank-remembered.log"; }
drawn "$OUT/$MODE-blank-3-remembered.png" "$MODE: and draws it" >/dev/null || true
stop; rm -f "$RJ"

# 4. Control: the window without its check, the same frozen pages: it must stay blank (or the checks above prove
# nothing about a window that can't tell).
if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
  sed '/self.paint.watch(view)/d' "$bin" >"$RUN/no-check"
  if cmp -s "$bin" "$RUN/no-check"; then no "control: couldn't take the check out of $bin"; else
    start control env NV_PAINT_GIVE_UP_S=$G python3 -I "$RUN/no-check"
    freeze "$OUT/$MODE-blank-control.log" "" $((2 * G + 10))
    k="$OUT/$MODE-blank-4-control.png"; shot "$k"; c=$(colours "$k")
    if [ "$c" -lt "$MIN_COLOURS" ] && ! grep -q "trying the window again" "$OUT/$MODE-blank-control.log"; then
      ok "control: without the check the frozen page leaves the window blank ($c colours after $((2 * G + 10)) s)"
    else no "control: without the check the window drew $c colours, so the checks above can't tell"; fi
    stop; thaw
  fi
fi

# 5. The update signal (the .deb's postinst): the same process starts over on the code on disk and draws again.
rm -f "$RJ"
start update $CMD
drawn "$OUT/$MODE-blank-5-before-update.png" "$MODE: a window before the update" >/dev/null || true
# Nothing frozen here: the check must pass in the first mode (a working window must not start over for nothing).
for i in $(seq 1 30); do grep -q "the window draws (mode" "$OUT/$MODE-blank-update.log" && break; sleep 1; done
if grep -q "the window draws (mode" "$OUT/$MODE-blank-update.log" && ! grep -q "trying the window again" "$OUT/$MODE-blank-update.log"; then
  ok "$MODE: a working window passes the check in its first mode ($(sed -n 's/.*the window draws (mode \([a-z-]*\)).*/\1/p' "$OUT/$MODE-blank-update.log" | head -1))"
else no "$MODE: a working window didn't pass the check"; grep "nostr-vault-desktop:" "$OUT/$MODE-blank-update.log" | tail -5; fi
p=$(pgrep -u "$(id -u)" -f "$POSTINST_PATTERN" | head -1)
pkill -USR2 -u "$(id -u)" -f "$POSTINST_PATTERN"
for i in $(seq 1 20); do grep -q "updated: starting over" "$OUT/$MODE-blank-update.log" && break; sleep 1; done
sleep 6
if [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "updated: starting over" "$OUT/$MODE-blank-update.log" \
    && [ "$(grep -c 'nostr-vault-desktop: drawing mode ' "$OUT/$MODE-blank-update.log")" -ge 2 ]; then
  ok "$MODE: SIGUSR2 (the postinst's) starts the window over in place (pid $p)"
else no "$MODE: SIGUSR2: pid '${p}', $(grep -c 'nostr-vault-desktop: drawing mode ' "$OUT/$MODE-blank-update.log") starts"; tail -10 "$OUT/$MODE-blank-update.log"; fi
drawn "$OUT/$MODE-blank-6-after-update.png" "$MODE: and it draws again"
stop; rm -f "$RJ"

# 6. Control: a window without the handler (as every version before it) quits on the same signal, as the postinst
# wants of an old window.
if [ "${NV_WT_CONTROL:-1}" = 1 ]; then
  sed '/nv_paint.listen_for_update(/d' "$bin" >"$RUN/no-update"
  if cmp -s "$bin" "$RUN/no-update"; then no "control: couldn't take the update handler out of $bin"; else
    start oldwin python3 -I "$RUN/no-update"
    sleep 8
    p=$(pgrep -u "$(id -u)" -f "$RUN/no-update" | head -1)
    pkill -USR2 -u "$(id -u)" -f "$RUN/no-update"
    sleep 4
    if [ -n "$p" ] && [ ! -d "/proc/$p" ]; then ok "control: a window without the handler quits on SIGUSR2 (no old window lingers)"
    else no "control: a window without the handler is still running after SIGUSR2 (pid '${p}')"; fi
    stop
  fi
fi
