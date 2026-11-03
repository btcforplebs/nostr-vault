// The Live Vault panel's rules (no styles, so tests can import it). The panel draws the Vault list's lines
// (net/notify-watch.js vaultLines) beside whatever is open, and keeps still while you read it: lines that arrive after
// it was drawn go on top by themselves (no pill, Logen 2026-11-03), and a line that changes in place (a like that gained
// a face) keeps its slot. Twin of the iPad's LiveVault.swift.

/** Rows the panel draws at most. */
export const MAX_ROWS = 30
/** Faces at the top of the panel. */
export const TOP_FACES = 5

/** What the panel shows, taken when it is first drawn and moved on by `place` as lines come in: the ids of the
 *  first MAX_ROWS of `lines` (newest first) and the newest moment among them (`now` when there are none). */
export const snapshot = (lines, now = Math.floor(Date.now() / 1000)) =>
  ({ ids: lines.slice(0, MAX_ROWS).map(r => r.id), top: lines[0]?.created_at ?? now })

/**
 * `lines` (newest first) against the snapshot on screen -> { rows, held }.
 * `rows`: the snapshot's lines in the order they were drawn, each in its latest form (a line gone from `lines`, blocked
 * or deleted, drops out), then lines older than its newest that came in late, below them, up to MAX_ROWS. Nothing
 * already drawn moves. `held`: lines newer than the snapshot, not drawn yet.
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

/** What the faces on top stand for: "84 people since you looked", "12 people lately" (the "+79" alone said nothing). */
export const facesText = (people, news) => `${people.toLocaleString()} ${people === 1 ? "person" : "people"} ${news ? "since you looked" : "lately"}`

/** The snapshot after `lines` came in: lines newer than it go on top, newest first; every line already drawn (late
 *  older ones included) keeps its order below them. No snapshot yet takes a fresh one. */
export function place(lines, shown) {
  if (!shown) return snapshot(lines)
  const { rows, held } = splitShown(lines, shown)
  return { ids: [...held, ...rows].slice(0, MAX_ROWS).map(r => r.id), top: Math.max(shown.top, held[0]?.created_at ?? shown.top) }
}

/** Whether two snapshots are the same. */
export const sameShot = (a, b) => a === b || (!!a && !!b && a.top === b.top && a.ids.length === b.ids.length && a.ids.every((id, i) => id === b.ids[i]))

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
