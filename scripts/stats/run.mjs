#!/usr/bin/env node
// The daily stats scan for nostrvault.app/stats. Read-only: it fetches public notes and the GitHub release list,
// and writes two files:
//   --out   the public totals (website/stats/stats.json by default): totals only, no keys, no list
//   --state the local poster records (scripts/stats/posters.json by default, gitignored): keys and dates, kept on
//           the box that runs the scan so tomorrow's scan starts from everyone found so far. Never publish it.
// Method (RESEARCH/NV_USER_STATS_2026_11_14.md): build a pool of candidate posters, then read each candidate's
// kind 1 / 1111 notes since SINCE on the relays below and keep the ones tagged ["client", "Nostr Vault …"].
// A client tag is not a single letter, so no relay can filter on it; the pool is what makes the scan possible.
//
//   node scripts/stats/run.mjs [--out FILE] [--state FILE] [--seed-file FILE] [--firehose-hours N] [--dry-run]

import { readFile, writeFile, rename, mkdir } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { COUNTED_KINDS, SINCE, collectPosters, mergePosters, nvPlatform, isExcluded, publicTotals, postersFromJson, postersToJson } from "./count.mjs"
import { downloadTotal } from "./github.mjs"
import { queryRelays, closeAll } from "./nostr.mjs"

const HERE = dirname(fileURLToPath(import.meta.url))

export const RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.primal.net",
  "wss://relay.snort.social",
  "wss://relay.btcforplebs.com",
  "wss://nostr.wine",
  "wss://relay.nostr.band",
]

/** Whose network seeds the pool: Logen and the Nostr Vault account. They are seeds only, never counted. */
export const SEEDS = [
  "61bf790b2094afb03495c9e136acf615be0fccc2cb95b5acfb5f6ccefe18b062",
  "4f5f4c7482314c2cc54d54ee6987ccba6aadd9814944339ba5b6411a2fe30c28",
]

/** Fewer relays than this answering the poster scan means the scan is not trusted: nothing is written. */
export const MIN_RELAYS = 3

const HEX = /^[0-9a-f]{64}$/

export function parseArgs(argv) {
  const args = { out: join(HERE, "../../website/stats/stats.json"), state: join(HERE, "posters.json"), seedFile: null, firehoseHours: 72, dryRun: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--out") args.out = argv[++i]
    else if (a === "--state") args.state = argv[++i]
    else if (a === "--seed-file") args.seedFile = argv[++i]
    else if (a === "--firehose-hours") args.firehoseHours = Number(argv[++i])
    else if (a === "--dry-run") args.dryRun = true
    else throw new Error(`unknown argument ${a}`)
  }
  if (!(args.firehoseHours >= 0)) throw new Error("--firehose-hours must be a number of hours")
  return args
}

const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a)
const unix = s => Math.floor(Date.parse(s + "T00:00:00Z") / 1000)

async function readJson(file) {
  try { return JSON.parse(await readFile(file, "utf8")) } catch (e) { if (e.code === "ENOENT") return null; throw e }
}

/** Writes through a temp file and a rename, so a reader never sees half a file. */
async function writeAtomic(file, text) {
  await mkdir(dirname(file), { recursive: true })
  await writeFile(file + ".tmp", text)
  await rename(file + ".tmp", file)
}

/** The candidate pool: who might have posted from Nostr Vault. Returns { pool, direct } (direct = notes found on the way). */
export async function buildPool({ relays, known, seedExtra, firehoseHours, now, q = queryRelays }) {
  const pool = new Set([...known, ...seedExtra])
  const add = pk => { if (HEX.test(pk) && !isExcluded(pk)) pool.add(pk) }
  const since = unix(SINCE)

  // The seeds' follows.
  const follows = await q(relays, { kinds: [3], authors: SEEDS }, { maxPages: 1 })
  for (const ev of follows.events) for (const t of ev.tags ?? []) if (t[0] === "p") add(t[1])
  log(`pool after follows: ${pool.size}`)

  // Everyone who follows a seed.
  const followers = await q(relays, { kinds: [3], "#p": SEEDS }, { maxPages: 10 })
  for (const ev of followers.events) add(ev.pubkey)
  log(`pool after followers: ${pool.size}`)

  // Everyone who replied to, mentioned or reacted to a seed since SINCE.
  const tagged = await q(relays, { kinds: [1, 1111, 7, 6], "#p": SEEDS, since }, { maxPages: 20 })
  for (const ev of tagged.events) add(ev.pubkey)
  log(`pool after p-tags: ${pool.size}`)

  // A sample of the last hours of public notes: anyone tagged Nostr Vault in it is a candidate (and a direct find).
  const direct = []
  if (firehoseHours > 0) {
    const sample = await q(relays, { kinds: COUNTED_KINDS, since: now - firehoseHours * 3600 }, { maxPages: 40 })
    for (const ev of sample.events) if (nvPlatform(ev)) { add(ev.pubkey); direct.push(ev) }
    log(`pool after ${firehoseHours} h sample (${sample.events.length} notes, ${direct.length} tagged): ${pool.size}`)
  }
  return { pool, direct }
}

/**
 * Reads every candidate's notes since SINCE, `batch` authors a filter. A batch whose notes run past maxPages on any
 * relay is split in half and read again, down to one author, so a busy batch is never cut short.
 * Returns the tagged notes, the relays that answered at least 90% of the filters, and how many single authors were
 * still cut short (busier than maxPages pages on their own).
 */
export async function scanPosters({ relays, pool, q = queryRelays, batch = 100, maxPages = 40 }) {
  const since = unix(SINCE)
  const queue = []
  const authors = [...pool]
  for (let i = 0; i < authors.length; i += batch) queue.push(authors.slice(i, i + batch))
  const events = []
  const answeredCount = new Map(relays.map(r => [r, 0]))
  const firstWhy = new Map()
  let filters = 0
  let cutShort = 0
  let read = 0
  while (queue.length) {
    const group = queue.shift()
    const res = await q(relays, { kinds: COUNTED_KINDS, authors: group, since }, { maxPages })
    filters++
    for (const r of res.answered) answeredCount.set(r, answeredCount.get(r) + 1)
    for (const [r, w] of Object.entries(res.why ?? {})) if (!firstWhy.has(r)) firstWhy.set(r, w)
    if (res.capped?.length && group.length > 1) {
      const half = Math.ceil(group.length / 2)
      queue.unshift(group.slice(0, half), group.slice(half))
      continue
    }
    if (res.capped?.length) cutShort++
    for (const ev of res.events) if (nvPlatform(ev)) events.push(ev)
    read += group.length
    if (filters % 10 === 0) log(`scanned ${read} of ${authors.length}`)
  }
  const answered = relays.filter(r => filters === 0 || answeredCount.get(r) >= Math.ceil(filters * 0.9))
  // One line per relay for the log: how many filters it answered, and the first reason it failed one.
  const perRelay = relays.map(r => `${r.replace("wss://", "")} ${answeredCount.get(r)}/${filters}${firstWhy.has(r) ? ` (first failure: ${firstWhy.get(r)})` : ""}`)
  return { events, answered, cutShort, perRelay }
}

export async function main(argv = process.argv.slice(2), { q = queryRelays, fetchFn = fetch, nowSec = () => Math.floor(Date.now() / 1000) } = {}) {
  const args = parseArgs(argv)
  const now = nowSec()
  const previous = postersFromJson(await readJson(args.state))
  const seedExtra = args.seedFile ? ((await readJson(args.seedFile)) ?? []).filter(pk => HEX.test(pk)) : []
  log(`known posters: ${previous.size}, extra seeds: ${seedExtra.length}`)

  const { pool, direct } = await buildPool({ relays: RELAYS, known: previous.keys(), seedExtra, firehoseHours: args.firehoseHours, now, q })
  const scan = await scanPosters({ relays: RELAYS, pool, q })
  for (const line of scan.perRelay ?? []) log(`relay ${line}`)
  log(`relays answering: ${scan.answered.join(" ") || "none"} (${scan.answered.length} of ${RELAYS.length}); authors cut short: ${scan.cutShort}`)
  if (scan.answered.length < MIN_RELAYS) {
    log(`only ${scan.answered.length} relays answered (need ${MIN_RELAYS}); nothing written`)
    return 2
  }

  const posters = mergePosters(previous, collectPosters([...scan.events, ...direct]))
  let downloads = null
  try { downloads = await downloadTotal(fetchFn) } catch (e) { log(`GitHub downloads not read: ${e.message}`) }
  const totals = publicTotals(posters, { now, downloads, relays: scan.answered.length })
  log(`posting users ${totals.posting_users}, 7 d ${totals.active_7d}, 30 d ${totals.active_30d}, downloads ${downloads}`)

  if (args.dryRun) {
    console.log(JSON.stringify(totals, null, 2))
    return 0
  }
  await writeAtomic(args.state, JSON.stringify(postersToJson(posters)) + "\n")
  await writeAtomic(args.out, JSON.stringify(totals, null, 2) + "\n")
  log(`wrote ${args.out}`)
  return 0
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().then(code => { closeAll(); process.exit(code) }, e => { console.error(e); closeAll(); process.exit(1) })
}
