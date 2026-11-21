// nostrvault.app/stats history: one line per day in stats-history.jsonl, the public totals only.
// `node history.mjs <stats.json> <stats-history.jsonl>` appends today's line after a successful scan (stats-job.sh).
// `node history.mjs --rebuild <posters.json> <stats-history.jsonl>` fills the days from SINCE up to the first
// scanned line with "reconstructed": true lines rebuilt from posters.json (see rebuildLines).
// A line holds the date and posting_users, by_platform, active_7d, active_30d, github_downloads: never a key or a list.
import { readFile, appendFile, writeFile, rename } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import { SINCE, isExcluded, publicTotals, postersFromJson } from "./count.mjs"

const FIELDS = ["posting_users", "by_platform", "active_7d", "active_30d", "github_downloads"]

/** The history line for a stats file: { date, ...the five totals }, or null for a file without a date or a count. */
export function historyLine(stats) {
  if (!stats || typeof stats.generated_at !== "string" || !Number.isFinite(stats.posting_users)) return null
  const date = stats.generated_at.slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null
  const line = { date }
  for (const f of FIELDS) line[f] = stats[f] ?? null
  return line
}

/** The date of the last line in the history text, or null. */
export function lastDate(text) {
  const lines = String(text ?? "").trim().split("\n").filter(Boolean)
  if (!lines.length) return null
  try { return JSON.parse(lines[lines.length - 1]).date ?? null } catch { return null }
}

/** Appends the stats file's line unless the history already has that day (or a later one). Returns what it did. */
export async function appendHistory(statsPath, historyPath) {
  const line = historyLine(JSON.parse(await readFile(statsPath, "utf8")))
  if (!line) return "skipped: stats file has no date or count"
  let text = ""
  try { text = await readFile(historyPath, "utf8") } catch (e) { if (e.code !== "ENOENT") throw e }
  const last = lastDate(text)
  if (last && last >= line.date) return `skipped: history already has ${last}`
  const sep = text && !text.endsWith("\n") ? "\n" : ""
  await appendFile(historyPath, sep + JSON.stringify(line) + "\n")
  return `appended ${line.date}`
}

const DAY = 86400
const dayOf = sec => new Date(sec * 1000).toISOString().slice(0, 10)
const startOf = date => Date.parse(`${date}T00:00:00Z`) / 1000

/**
 * One "reconstructed" line per UTC day from `since` up to (not including) `until`, from poster records alone:
 * posting_users = posters first seen by the end of that day, by_platform = those posters by their main platform
 * (as of the last scan: a poster's note counts are not kept per day). active_7d/30d and github_downloads cannot be
 * rebuilt from these records, so they are null.
 */
export function rebuildLines(posters, { since = SINCE, until }) {
  const recs = [...posters].filter(([pk]) => !isExcluded(pk))
  const lines = []
  for (let t = startOf(since); t < startOf(until); t += DAY) {
    const seen = new Map(recs.filter(([, r]) => r.first < t + DAY))
    const { posting_users, by_platform } = publicTotals(seen, { now: t + DAY, downloads: null, relays: null })
    lines.push({ date: dayOf(t), posting_users, by_platform, active_7d: null, active_30d: null, github_downloads: null, reconstructed: true })
  }
  return lines
}

/** Rewrites the history: rebuilt lines for every day before the first scanned line (or before `today`), then the scanned lines. */
export async function rebuildHistory(postersPath, historyPath, { today = dayOf(Date.now() / 1000) } = {}) {
  const posters = postersFromJson(JSON.parse(await readFile(postersPath, "utf8")))
  let text = ""
  try { text = await readFile(historyPath, "utf8") } catch (e) { if (e.code !== "ENOENT") throw e }
  const scanned = text.split("\n").filter(Boolean).map(l => JSON.parse(l)).filter(l => !l.reconstructed)
  const until = scanned.length ? scanned[0].date : today
  const rebuilt = rebuildLines(posters, { until })
  const tmp = `${historyPath}.tmp`
  await writeFile(tmp, [...rebuilt, ...scanned].map(l => JSON.stringify(l) + "\n").join(""))
  await rename(tmp, historyPath)
  return `rebuilt ${rebuilt.length} days (${rebuilt[0]?.date ?? "none"}..${rebuilt.at(-1)?.date ?? "none"}), kept ${scanned.length} scanned`
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const rebuild = args[0] === "--rebuild"
  const [inPath, historyPath] = rebuild ? args.slice(1) : args
  if (!inPath || !historyPath) {
    console.error("usage: node history.mjs <stats.json> <stats-history.jsonl> | --rebuild <posters.json> <stats-history.jsonl>")
    process.exit(64)
  }
  const run = rebuild ? rebuildHistory(inPath, historyPath) : appendHistory(inPath, historyPath)
  run.then(r => console.log(`history: ${r}`), e => { console.error(`history: ${e.message}`); process.exit(1) })
}
