# nostrvault.app/stats: the daily count

`run.mjs` counts the people who post from Nostr Vault. It reads public notes only, signs nothing and publishes nothing.
It writes one totals file for the page at `website/stats/` (`index.html` + `stats.js`).

## Method

The apps add `["client", "Nostr Vault on iOS"]` (or "… on iPadOS", "… on MacOS", "… on Android", "… on Web") to
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
   (`EXCLUDED_PREFIXES`).

A poster stays counted once found, even if a later scan misses their notes. Each poster's main platform is the one
they post from most. "Active" means their last tagged note is within 7 or 30 days.

This counts posters only, so it is a floor: readers who never post, and posters outside the pool, are missed. It is
the same method as RESEARCH/NV_USER_STATS_2026_11_14.md, which found about 70 posters on 2026-11-14.

## Files

| File | What | Public? |
|---|---|---|
| `website/stats/stats.json` (`--out`) | totals: posting users, by platform, 7/30-day active, GitHub release downloads | yes: the page reads it |
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

**Not installed anywhere yet.** The daily job (cron or launchd) and the way `stats.json` reaches the live site wait
on Logen. The site image is built from `website/` at deploy time, so a daily file needs a mount or a copy into the
running container. Until a file exists, the page says the numbers haven't been counted yet.
