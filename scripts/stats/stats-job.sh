#!/bin/sh
# nostrvault.app/stats daily job (launchd com.nostrvault.stats on prod-mini, every 15 min, gui session).
# Lives in the repo at scripts/stats/stats-job.sh; the box runs a copy at ~/.buzz/REPOS/nv-stats-job/stats-job.sh,
# and that copy keeps itself and stats/ in step with master (step 1), so nobody copies it by hand again.
#
# 1. When a scan is due (no scan has written stats.json yet this UTC day; see below), first refresh the code from master: fetch
#    master into a bare clone (repo.git), git-archive scripts/stats and website/stats (the page test imports the
#    page's script) into a staging dir, run `node --test` on scripts/stats/test there, and swap staging into stats/
#    only if every test passes. Any failure (fetch, archive, tests) logs why and keeps the last good stats/.
#    A changed stats-job.sh from a passing master is installed over this file for the next run.
# 2. Run the scan (scripts/stats/run.mjs, about 10 min). A scan that fails its relay gate writes nothing and the old
#    totals stay; the next try waits 3 hours (scan.tried), so a failing day costs the relays a scan every 3 hours.
#    A scan that wrote stats.json records its UTC start day in scan.day, so the day gets no second scan.
#    After a scan that wrote stats.json, stats/history.mjs appends that day's public totals (no keys) to
#    stats-history.jsonl, at most one line per day.
# 3. Copy stats.json and stats-history.jsonl into the running site container whenever the live copy differs, so a redeploy (which starts
#    from the image, without the file) has the numbers again within 15 minutes.
# posters.json (public keys + dates of posters) stays in this folder and is never copied anywhere.
#
# `stats-job.sh --refresh-only` runs step 1 alone (a dry run: no scan, no copy). STATS_REF / STATS_REPO override
# the branch and the repository (used to prove a bad ref keeps the old copy).
export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
D="$(cd "$(dirname "$0")" && pwd)"
LOG="$D/stats.log"
CONTAINER=website-website-1
TARGET_DIR=/usr/share/nginx/html/stats
REPO="${STATS_REPO:-https://github.com/btcforplebs/nostr-vault.git}"
REF="${STATS_REF:-master}"
cd "$D" || exit 1

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# Step 1. Returns 0 when stats/ now holds a tested copy of $REF (new or unchanged), 1 when it kept the old one.
refresh() {
  old="$(cat stats/.source-sha 2>/dev/null || echo unknown)"
  if [ ! -d repo.git ]; then
    git clone -q --bare --no-tags "$REPO" repo.git >> "$LOG" 2>&1 || { rm -rf repo.git; log "refresh: clone of $REPO failed; keeping stats/ ($old)"; return 1; }
  fi
  if ! git -C repo.git fetch -q --no-tags "$REPO" "$REF" >> "$LOG" 2>&1; then
    log "refresh: fetch of $REF failed; keeping stats/ ($old)"; return 1
  fi
  sha="$(git -C repo.git rev-parse FETCH_HEAD)"
  log "refresh: pulled $REF $sha (stats/ is $old)"
  [ "$sha" = "$old" ] && { log "refresh: already at $sha"; return 0; }
  rm -rf staging && mkdir staging
  if ! git -C repo.git archive "$sha" scripts/stats website/stats | tar -x -C staging; then
    rm -rf staging; log "refresh: archive of $sha failed; keeping stats/ ($old)"; return 1
  fi
  # Test files by name: Node 22.14 (prod-mini) does not take a folder. The spec reporter prints ✖/ℹ lines off a TTY too.
  if ! node --test --test-reporter=spec staging/scripts/stats/test/*.test.mjs > staging.test.log 2>&1; then
    log "refresh: tests FAILED on $sha; keeping stats/ ($old). Failing tests:"
    { grep -E '^✖|^ℹ (pass|fail)' staging.test.log || tail -8 staging.test.log; } | head -12 >> "$LOG"
    rm -rf staging staging.test.log; return 1
  fi
  log "refresh: tests pass on $sha ($(grep -E '^ℹ pass' staging.test.log | sed 's/ℹ //'))"
  echo "$sha" > staging/scripts/stats/.source-sha
  rm -rf stats.old
  mv stats stats.old 2>/dev/null
  if mv staging/scripts/stats stats; then
    rm -rf stats.old staging staging.test.log
    log "refresh: stats/ is now $sha"
  else
    mv stats.old stats 2>/dev/null; rm -rf staging staging.test.log
    log "refresh: swap failed; kept stats/ ($old)"; return 1
  fi
  # This file follows master too. A rename leaves the running shell reading the old file, so this is safe mid-run.
  if [ -f stats/stats-job.sh ] && ! cmp -s stats/stats-job.sh "$D/stats-job.sh"; then
    cp stats/stats-job.sh "$D/stats-job.sh.new" && chmod 755 "$D/stats-job.sh.new" && mv "$D/stats-job.sh.new" "$D/stats-job.sh" \
      && log "refresh: installed stats-job.sh from $sha (used from the next run)"
  fi
  return 0
}

if [ "$1" = "--refresh-only" ]; then
  refresh; exit $?
fi

# One scan per UTC day, from the first tick after 00:00 UTC (7 PM US Eastern in winter). scan.day holds the UTC
# day of the last scan that wrote stats.json; without it (first run of this version), stats.json's own UTC day counts.
today="$(date -u +%F)"
last="$(cat scan.day 2>/dev/null)"
[ -z "$last" ] && [ -f stats.json ] && last="$(date -u -r stats.json +%F 2>/dev/null)"
due=0
[ "$last" != "$today" ] && due=1
# A failed try today waits 3 hours. A try from yesterday never holds back today's first scan.
[ -f scan.tried ] && [ "$(date -u -r scan.tried +%F 2>/dev/null)" = "$today" ] \
  && [ -z "$(find scan.tried -mmin +180 2>/dev/null)" ] && due=0
if [ "$due" = 1 ]; then
  # A lock left by a killed scan (a run takes about 10 minutes) is cleared after an hour.
  find scan.lock -maxdepth 0 -mmin +60 -exec rmdir {} \; 2>/dev/null
  if mkdir scan.lock 2>/dev/null; then
    touch scan.tried
    refresh
    log "scan start ($(cat stats/.source-sha 2>/dev/null || echo unknown))"
    seed=""; [ -f seed-posters.json ] && seed="--seed-file seed-posters.json"
    node stats/run.mjs --out stats.json --state posters.json $seed >> "$LOG" 2>&1
    rc=$?
    log "scan exit $rc"
    # One line per day of public totals (no keys) after a scan that wrote stats.json.
    [ "$rc" = 0 ] && echo "$today" > scan.day
    [ "$rc" = 0 ] && [ -f stats/history.mjs ] && node stats/history.mjs stats.json stats-history.jsonl >> "$LOG" 2>&1
    rmdir scan.lock
  fi
fi

# stats.json and stats-history.jsonl (totals only, never a key) go next to each other in the site container.
for f in stats.json stats-history.jsonl; do
  [ -f "$f" ] || continue
  if ! docker exec "$CONTAINER" cat "$TARGET_DIR/$f" 2>/dev/null | cmp -s - "$f"; then
    if docker cp "$f" "$CONTAINER:$TARGET_DIR/$f" >> "$LOG" 2>&1 && docker exec "$CONTAINER" chmod 644 "$TARGET_DIR/$f"; then
      log "copied $f into $CONTAINER"
    else
      log "copy of $f into $CONTAINER FAILED"
    fi
  fi
done
