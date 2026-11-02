// The Live Vault panel's rules (no styles, so tests can import it). The panel draws the Vault list's lines
// (net/notify-watch.js vaultLines) beside whatever is open, and keeps still while you read it: lines that arrive after
// it was drawn wait behind its "N new" pill, and a line that changes in place (a like that gained a face) keeps its slot.

/** Rows the panel draws at most. */
export const MAX_ROWS = 30
/** Faces at the top of the panel. */
export const TOP_FACES = 5

/** What the panel shows, taken when it is first drawn and when the pill is clicked, never in between: the ids of the
 *  first MAX_ROWS of `lines` (newest first) and the newest moment among them (`now` when there are none). */
export const snapshot = (lines, now = Math.floor(Date.now() / 1000)) =>
  ({ ids: lines.slice(0, MAX_ROWS).map(r => r.id), top: lines[0]?.created_at ?? now })

/**
 * `lines` (newest first) against the snapshot on screen -> { rows, held }.
 * `rows`: the snapshot's lines in the order they were drawn, each in its latest form (a line gone from `lines`, blocked
 * or deleted, drops out), then lines older than its newest that came in late, below them, up to MAX_ROWS. Nothing
 * already drawn moves. `held`: lines newer than the snapshot, for the pill.
 */
export function splitShown(lines, { ids, top }) {
  const byId = new Map(lines.map(r => [r.id, r]))
  const on = new Set(ids)
  const rows = ids.map(id => byId.get(id)).filter(Boolean)
  const rest = lines.filter(r => !on.has(r.id))
  const held = rest.filter(r => r.created_at > top)
  const late = rest.filter(r => r.created_at <= top)
  return { rows: [...rows, ...late].slice(0, Math.max(MAX_ROWS, rows.length)), held }
}

/** Who to show on top: the people behind `lines`, newest first, each once, at most `n`. -> { faces, more } */
export function topFaces(lines, n = TOP_FACES) {
  const seen = new Set()
  for (const r of lines) for (const pk of r.actors) seen.add(pk)
  const all = [...seen]
  return { faces: all.slice(0, n), more: Math.max(0, all.length - n) }
}

/** The pill's count: lines newer than the last look, else the ones waiting to be drawn; 0 hides it. */
export const pillCount = (unread, held) => (unread > 0 ? unread : held)

/** A line's text on one row: `nostr:` people as a short @npub, links to notes left out, spaces folded. */
export const rowText = (s = "") =>
  s.replace(/nostr:((?:npub|nprofile)1[02-9ac-hj-np-z]+)/g, (_, b) => `@${b.slice(0, 12)}…`)
    .replace(/nostr:(?:note|nevent|naddr)1[02-9ac-hj-np-z]+/g, "").replace(/\s+/g, " ").trim()

// Folded or open, per account in this browser. The key ends in ":<pubkey>", so signing out wipes it with the rest of
// the account's keys (haven/vault.js accountKeys).
const FOLD = "nv-space-folded"
export function readFolded(me, storage = globalThis.localStorage) {
  try { return storage?.getItem(`${FOLD}:${me}`) === "1" } catch { return false }
}
export function writeFolded(me, folded, storage = globalThis.localStorage) {
  try { storage?.setItem(`${FOLD}:${me}`, folded ? "1" : "0") } catch {}
}
