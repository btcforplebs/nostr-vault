// The Vault mode menu's "New" marks (iPhone VaultModePill newModes): a mode is new when something someone else sent
// arrived after you last opened it. Each mode's last look is kept per account in this browser. The first time, the
// newest arrival is taken as seen, so a new browser doesn't light every mode at once. Followers keep their own mark
// (vault-lists.js followersSeenAt), which the Followers list already uses for Newest.
import { ARTICLE_KIND, HIGHLIGHT_KIND } from "./vault-lists.js"

const KEY = "nv-vault-seen"

/** The mode an inbound event of `kind` shows in (VaultMode.listing), or null. */
export function modeOfKind(kind) {
  if (kind === 7) return "likes"
  if (kind === 9735) return "zaps"
  if (kind === ARTICLE_KIND) return "articles"
  if (kind === HIGHLIGHT_KIND) return "highlights"
  if (kind === 1 || kind === 6 || kind === 1111) return "notes"
  return null
}

/** The newest arrival per mode from others (blocked left out); "activity" is the newest of all. */
export function newestByMode(inbound, me, blocked = new Set()) {
  const out = {}
  for (const ev of inbound) {
    if (!ev || ev.pubkey === me || blocked.has(ev.pubkey)) continue
    const m = modeOfKind(ev.kind)
    if (!m) continue
    for (const k of [m, "activity"]) if (!(out[k] >= ev.created_at)) out[k] = ev.created_at
  }
  return out
}

export function readSeen(me, storage = globalThis.localStorage) {
  try { const s = JSON.parse(storage?.getItem(`${KEY}:${me}`) ?? "null"); return s && typeof s === "object" ? s : null } catch { return null }
}
export const writeSeen = (me, seen, storage = globalThis.localStorage) => storage?.setItem(`${KEY}:${me}`, JSON.stringify(seen))

/** The marks with `mode` seen up to `at` (never moved back). */
export const markSeen = (seen, mode, at) => ({ ...seen, [mode]: Math.max(seen?.[mode] ?? 0, at ?? 0) })

/** The first look: everything that has arrived counts as seen. */
export const baseline = newest => ({ ...newest })

/** Modes with an arrival after their last look, other than `current` (the one on screen). Followers: `followersAt`
 *  (the newest follower's time) after `followersSeen`. */
export function newModes(newest, seen, { current, followersAt = 0, followersSeen = 0 } = {}) {
  const out = new Set()
  for (const [m, at] of Object.entries(newest)) if (at > (seen?.[m] ?? 0)) out.add(m)
  if (followersAt > followersSeen) out.add("followers")
  out.delete(current)
  return out
}
