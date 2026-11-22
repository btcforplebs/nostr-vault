# nostrvault.app/stats: the daily count

`run.mjs` counts the people who post from Nostr Vault. It reads public notes only, signs nothing and publishes nothing.
It writes one totals file for the page at `website/stats/` (`index.html` + `stats.js`).

## Method

The apps add `["client", "Nostr Vault on iOS"]` (or "… on iPadOS", "… on MacOS", "… on Android", "… on Linux", "… on Web") to
kind 1 notes and kind 1111 comments: `EventPublisher.appendClientTag` in the Apple and Android apps, and
`web-vault/src/net/client-tag.js`. Relays can't filter on a multi-letter tag, so the scan works in two steps:

1. **Candidate pool.** It starts from yesterday's posters (the state file) and adds:
   - the follows of Logen and the Nostr Vault account,
   - everyone whose follow list includes either of them,
   - everyone who p-tagged either of them since 2026-05-01,
   - anyone tagged Nostr Vault in the last 72 hours of public notes.
2. **Scan.** It reads every candidate's kind 1 and 1111 notes since 2026-05-01 on the seven relays in `RELAYS`, 100
   authors per filter, and keeps the notes carrying the tag. A filter whose notes run past 40 pages of 500 on any
   relay is split in half and read again, so a busy batch is never cut short. The log names any single author still
   too busy to read in full. The project's own and test keys are never counted
   (`EXCLUDED_PREFIXES`), nor are the Linux CI's client tag test notes ("client tag e2e from …", throwaway keys
   that reached public relays until #2348); a key whose notes are all such test notes is dropped from the state file.

A poster stays counted once found, even if a later scan misses their notes. Each poster's main platform is the one
they post from most. "Active" means their last tagged note is within 7 or 30 days.

This counts posters only, so it is a floor: readers who never post, and posters outside the pool, are missed. It is
the same method as RESEARCH/NV_USER_STATS_2026_11_14.md, which found about 70 posters on 2026-11-14.

## Files

| File | What | Public? |
|---|---|---|
| `website/stats/stats.json` (`--out`) | totals: posting users, by platform, 7/30-day active, GitHub release downloads | yes: the page reads it |
| `stats-history.jsonl` (next to `stats.json` on the job box) | one line per day: date, posting users, by platform, 7/30-day active, GitHub downloads (`history.mjs`). Days before the first scan (from 2026-05-01) are rebuilt once with `history.mjs --rebuild` from `posters.json` and marked `"reconstructed": true`: posting users = posters first seen by the end of that day, platform = each poster's main platform as of the last scan. Their `active_7d`, `active_30d` and `github_downloads` are `null`, because the poster records keep only first/last dates and no download history. | yes: the job copies it next to `stats.json`, and the page draws "Posting users over time" from it (`website/stats/chart.js`). It holds totals only, never a key. |
| `scripts/stats/posters.json` (`--state`) | one record per poster: public key, first/last note date, note count per platform | **no**: it stays on the box that runs the scan (gitignored). The page and the totals file never contain a key. |

If fewer than 3 relays answer the scan, nothing is written and the exit code is 2, so a relay outage never shows
a lower number. If GitHub can't be read, `github_downloads` is `null` and the page shows a dash.

## Run

```sh
node scripts/stats/run.mjs --dry-run            # print the totals, write nothing
node scripts/stats/run.mjs                      # write website/stats/stats.json and scripts/stats/posters.json
node scripts/stats/run.mjs --out /srv/stats.json --state /var/lib/nv-stats/posters.json
node --test scripts/stats/test/                 # tests
```

Needs Node 22 or later (built-in WebSocket and fetch, no npm install). A run takes about 20 minutes.

**The daily job** is `stats-job.sh`, run by launchd (`com.nostrvault.stats`, every 15 min) on prod-mini from a copy at
`~/.buzz/REPOS/nv-stats-job/stats-job.sh`. It scans once per UTC day, at the first tick after 00:00 UTC (7 PM US
Eastern in winter; a failed scan retries every 3 hours that day; `scan.day` records the day done). Before each daily scan it fetches master, runs these tests on master's
`scripts/stats` (plus `website/stats`, which the page test imports) in a staging dir and swaps it in only if they pass;
a failed fetch or test keeps the last good copy and says why in `stats.log`. It installs a changed `stats-job.sh`
the same way, so merging to master is enough: no hand copy. `stats-job.sh --refresh-only` does just that step.
It then copies `stats.json` and `stats-history.jsonl` into the running site container, so the page has today's numbers and chart.
