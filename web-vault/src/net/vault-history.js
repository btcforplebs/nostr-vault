// When the dashboard's jobs last ran, per account, in this browser (the phone's VaultHistory in UserDefaults):
// notes import, notes backup (Export notes / Backup file) and media backup. Also the relative-time wording the
// dashboard uses ("2 hours ago", "yesterday"), as the phone's .relative(presentation: .named).

const KEY = "nv-vault-history"
const listeners = new Set()

export function readHistory(me, storage = globalThis.localStorage) {
  try { const v = JSON.parse(storage?.getItem(`${KEY}:${me}`) ?? "{}"); return v && typeof v === "object" ? v : {} } catch { return {} }
}

/** Notes `job` ("notesImport" | "notesBackup" | "mediaBackup") as done now. */
export function markRan(me, job, at = Date.now(), storage = globalThis.localStorage) {
  const next = { ...readHistory(me, storage), [job]: at }
  try { storage?.setItem(`${KEY}:${me}`, JSON.stringify(next)) } catch {}
  for (const cb of listeners) cb()
  return next
}
export const onHistory = cb => { listeners.add(cb); return () => listeners.delete(cb) }

const UNITS = [["year", 365 * 86400], ["month", 30 * 86400], ["week", 7 * 86400], ["day", 86400], ["hour", 3600], ["minute", 60], ["second", 1]]

/** "2 hours ago", "yesterday", "now": `at` (ms) relative to `now` (ms). */
export function relative(at, now = Date.now(), locale = undefined) {
  const s = Math.round((at - now) / 1000)
  if (Math.abs(s) < 5) return "now"
  const fmt = new Intl.RelativeTimeFormat(locale, { numeric: "auto" })
  for (const [unit, sec] of UNITS) if (Math.abs(s) >= sec) return fmt.format(Math.round(s / sec), unit)
  return "now"
}

/** "Mon YYYY" for the import start date ("2023-01-01" -> "Jan 2023"). */
export function monthYear(ymd, locale = "en-US") {
  const d = new Date(`${ymd}T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? ymd : d.toLocaleDateString(locale, { month: "short", year: "numeric", timeZone: "UTC" })
}
