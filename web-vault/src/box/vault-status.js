// The words the Trust ranking card says about the engine's status read (haven-go vault_status.go), the same as
// the apps' VaultStatusText (HavenApp/Models/VaultStatus.swift, Android data/model/VaultStatus.kt). Pure, so
// test/box-vault-status.test.mjs checks them. Times are Unix seconds; `now` too.

const n = v => Number(v ?? 0).toLocaleString("en-US")

export const headline = s => s?.state === "running" ? "Ranking your web"
  : s?.state === "paused" ? (s.pausedWhy === "busy" ? "Paused while an import or copy runs" : "Paused while the window is open")
  : s?.state === "off" ? "Trust ranking is off here"
  : "Idle"

export const pausedHint = s => s?.state === "paused" && s.pausedWhy !== "busy" ? "It runs when the window is closed and Run in background is on." : null

/** The status for `hex`, or the first account when that one is not ranked here. */
export const accountOf = (s, hex) => s?.accounts?.find(a => a.account === String(hex ?? "").toLowerCase()) ?? s?.accounts?.[0] ?? null

export function ago(unix, now) {
  const secs = Math.max(0, Math.floor(now - unix))
  if (secs < 60) return "just now"
  if (secs < 3600) return `${Math.floor(secs / 60)} min ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)} h ago`
  const days = Math.floor(secs / 86400)
  return days === 1 ? "1 day ago" : `${days} days ago`
}

export function progress(a) {
  if (!(a?.ring > 0)) return null
  let line = `Ring ${a.ring}`
  if (a.ringDone != null && a.ringTotal > 0) line += ` · ${n(a.ringDone)} of ${n(a.ringTotal)} lists`
  else if (a.ringDone > 0) line += ` · ${n(a.ringDone)} lists read`
  if (a.running && a.listsRead > 0) line += ` · ${n(a.listsRead)} read this run`
  else if (!a.running && a.cut) line += " · waiting to go on"
  return line
}

export function finished(a, now) {
  if (!(a?.finishedAt > 0)) return a?.result ? "Not finished since the last change" : "No ranking yet"
  let line = `Finished ${ago(a.finishedAt, now)}`
  if (a.result) line += ` · ${n(a.result.people)} ${a.result.people === 1 ? "person" : "people"} ranked`
  if (a.capped) line += " · stopped at the size cap"
  return line
}

/** Distant connections at or over `bar` (whole steps, as the slider). */
export const distantAtBar = (r, bar) => (r?.distantByShown ?? []).slice(Math.min(100, Math.max(0, Math.ceil(bar)))).reduce((x, y) => x + y, 0)

export function distant(a, bar) {
  const r = a?.result
  if (!r) return null
  const used = bar ?? r.viewBar
  const count = distantAtBar(r, used)
  return `${n(count)} distant ${count === 1 ? "connection" : "connections"} at your bar (${Math.round(used)})`
}

export function distantFetch(a, now) {
  if (!(a?.distantFetchAt > 0)) return "Distant posts not fetched yet"
  const people = a.distantFetchPeople ?? 0
  return `Distant posts fetched ${ago(a.distantFetchAt, now)} · ${n(a.distantFetchNew ?? 0)} new from ${n(people)} ${people === 1 ? "person" : "people"}`
}

export const handoff = (h, now) => h?.tookAt > 0 ? `Took it ${ago(h.tookAt, now)}` : "Hasn't taken the ranking yet"

const ROLE_LABELS = { mac: "Desktop vault · full history", phone: "Phone", homeVault: "Mobile vault · new posts", browser: "Browser vault" }

/** A hand-off row's name: the device's own name (the engine's, else the box's devices list `names`, hex -> name),
 *  and its type only when it has none anywhere. */
export const handoffName = (h, names) => h?.name?.trim() || names?.get?.(h?.device)?.trim() || ROLE_LABELS[h?.role] || "A paired device"

/** "Updated just now": the age of the file the engine wrote. */
export const updated = (writtenAt, now) => writtenAt > 0 ? `Updated ${ago(writtenAt, now)}` : null
