#!/bin/sh
# Runs from nginx's /docker-entrypoint.d/ (website/Dockerfile) and stays in the background: once an hour it deletes the
# access log files (nginx.conf, access-YYYY-MM-DD.log) older than the last 7 days (today and the 6 before), so no entry is kept past 7 days.
dir=/var/log/nginx/site
(
  while :; do
    cutoff=$(date -u -d "@$(( $(date -u +%s) - 6 * 86400 ))" +%Y-%m-%d)
    for f in "$dir"/access-*.log; do
      [ -e "$f" ] || continue
      day=${f##*/access-}
      day=${day%.log}
      # "undated" (nginx.conf's fallback, not expected) sorts after every date: drop it rather than keep it forever.
      if [ "$day" \< "$cutoff" ] || [ "$day" = undated ]; then rm -f "$f"; fi
    done
    sleep 3600
  done
) </dev/null >/dev/null 2>&1 &
