// NIP-94 file notes (kind 1063) on the home vault's /files room (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md §1-§2,
// haven-go files_relay.go): read side only. The web writes nothing here (no 1063, no kind 5; Logen, 2026-11-12, web
// read-only), so only parse, merge, tombstone and the tile rule are here. Port of iOS Models/FileNote.swift; keep every
// branch the same as that file and Android's FileNotes.kt.

import { emojiPart, emojiOnlyHashes, emojiCopies } from "./emoji-notes.js"

export const FILE_NOTE_KIND = 1063
/** Back this far on a resubscribe, for notes stamped a little late. */
export const RESUBSCRIBE_OVERLAP = 600

const HEX64 = /^[0-9a-f]{64}$/
const WHOLE = /^[+-]?\d+$/ // Swift Int64(String): optional sign, digits only
export const isHex64 = s => typeof s === "string" && HEX64.test(s)

const strTags = ev => (Array.isArray(ev?.tags) ? ev.tags : []).map(t => (Array.isArray(t) ? t.filter(v => typeof v === "string") : []))
const all = (tags, name) => tags.filter(t => t.length >= 2 && t[0] === name).map(t => t[1])
const first = (tags, name) => all(tags, name)[0]
const createdAt = ev => (Number.isFinite(ev?.created_at) ? Math.trunc(ev.created_at) : 0)
const httpsLink = u => {
  if (!u.toLowerCase().startsWith("https://")) return false
  try { new URL(u); return true } catch { return false }
}

/** A note as the vault serves it, or null for anything it should never have taken (a reader does not trust the room
 *  blindly). -> { id, signer, createdAt, sha256, mime, size, owner, urls: url then each fallback, https only } */
export function parseFileNote(ev) {
  if (ev?.kind !== FILE_NOTE_KIND || typeof ev.id !== "string" || !ev.id || typeof ev.pubkey !== "string" || !ev.pubkey) return null
  if (!Array.isArray(ev.tags)) return null
  const t = strTags(ev)
  const x = first(t, "x"), m = first(t, "m"), sizeText = first(t, "size")
  if (!isHex64(x) || !m || sizeText === undefined || !WHOLE.test(sizeText)) return null
  const size = Number(sizeText)
  if (!Number.isSafeInteger(size) || size < 0) return null
  const ps = all(t, "p")
  if (ps.length !== 1 || !isHex64(ps[0])) return null
  const urls = [...all(t, "url"), ...all(t, "fallback")].filter(httpsLink)
  return { id: ev.id, signer: ev.pubkey, createdAt: createdAt(ev), sha256: x, mime: m, size: size || 0, owner: ps[0], urls }
}

/** A kind 5 on /files: it names the notes it deletes, says k 1063, and the hash it is about. Null otherwise. */
export function parseFileNoteDeletion(ev) {
  if (ev?.kind !== 5 || typeof ev.id !== "string" || !ev.id || typeof ev.pubkey !== "string" || !Array.isArray(ev.tags)) return null
  const t = strTags(ev)
  if (!all(t, "k").includes(String(FILE_NOTE_KIND))) return null
  const noteIDs = new Set(all(t, "e"))
  if (!noteIDs.size) return null
  return { id: ev.id, signer: ev.pubkey, createdAt: createdAt(ev), noteIDs, hashes: new Set(all(t, "x").filter(isHex64)) }
}

/** The live REQ every open Media tab keeps on /files. */
export const liveFilter = (owner, since) => ({ kinds: [FILE_NOTE_KIND, 5], "#p": [owner], ...(since !== undefined && since !== null ? { since } : {}) })

/** The websocket for /files on a vault: the mesh ingress base keeps its token path; a vault's own address gets /files. */
export function filesURL(base) {
  let u
  try { u = new URL(base) } catch { return null }
  const secure = u.protocol === "https:" || u.protocol === "wss:"
  const path = u.pathname.replace(/\/+$/, "")
  return `${secure ? "wss" : "ws"}://${u.host}${path}/files${u.search}`
}

/** The relay tag of the NIP-42 AUTH: over the mesh the vault pins it to its own mesh address (haven-go meshAuthURL);
 *  on the vault's own relay it is the address dialled. */
export const authRelayURL = (vaultNpub, connected) => (vaultNpub ? `ws://${vaultNpub}.fips/files` : String(connected))

/** Tile check (plan gap 3) for a note-only tile. `serverStatuses`: each named server's HEAD status (null = no answer);
 *  `vaultHas`: the home vault's answer (null = not asked or no answer). Hides only when every server said 404 and the
 *  vault lacks it: a server that didn't answer is not proof the file is gone. -> "visible" | "dimmed" | "hidden" */
export function tileState(serverStatuses, vaultHas) {
  if (vaultHas === true || serverStatuses.some(s => typeof s === "number" && s >= 200 && s <= 299)) return "visible"
  if (vaultHas === false && serverStatuses.every(s => s === 404)) return "hidden"
  return "dimmed"
}

/** What the live notes say, merged by hash. Deletions are kept so a note replayed after its deletion never comes back.
 *  `owner`: only this owner's notes count; unset takes the room's word. */
export class FileNotesState {
  constructor(owner) {
    this.owner = owner
    this.notes = new Map() // id -> note
    this.deleted = new Set()
    this.newestSeen = undefined
    this.changes = 0 // bumped on every note added or deleted, also those that leave the tiles as they were
  }

  /** Apply one event from the room. -> { added: sha256 } | { removed: sha256 } | null (no tile change). */
  apply(ev) {
    const at = createdAt(ev)
    const note = parseFileNote(ev)
    if (note) {
      if (this.owner && this.owner !== note.owner) return null
      this.#seen(at)
      if (this.deleted.has(note.id) || this.notes.has(note.id)) return null
      const had = this.hasLiveNote(note.sha256)
      this.notes.set(note.id, { ...note, emoji: emojiPart(ev) })
      this.changes++
      return had ? null : { added: note.sha256 }
    }
    const del = parseFileNoteDeletion(ev)
    if (del) {
      this.#seen(at)
      const touched = new Set()
      for (const id of del.noteIDs) {
        this.deleted.add(id)
        const gone = this.notes.get(id)
        if (gone) { this.notes.delete(id); touched.add(gone.sha256); this.changes++ }
      }
      // One hash per deletion here (the vault's and the apps' form).
      const removed = [...touched].sort().find(sha => !this.hasLiveNote(sha))
      if (removed) return { removed }
    }
    return null
  }

  /** Since when to ask again after a drop: the newest seen, less the overlap. */
  since() {
    return this.newestSeen === undefined ? undefined : Math.max(0, this.newestSeen - RESUBSCRIBE_OVERLAP)
  }

  hasLiveNote(sha256) {
    for (const n of this.notes.values()) if (n.sha256 === sha256) return true
    return false
  }

  /** One tile per hash, newest first: { sha256, mime, size, createdAt: newest note's, urls: every live note's links,
   *  newest note first, each once }. */
  tiles() {
    const byHash = new Map()
    for (const n of this.notes.values()) byHash.set(n.sha256, [...(byHash.get(n.sha256) ?? []), n])
    const newestFirst = (a, b) => (a.createdAt !== b.createdAt ? b.createdAt - a.createdAt : a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
    return [...byHash].map(([sha256, group]) => {
      const ordered = group.sort(newestFirst)
      return { sha256, mime: ordered[0].mime, size: ordered[0].size, createdAt: ordered[0].createdAt, urls: [...new Set(ordered.flatMap(n => n.urls))] }
    }).sort((a, b) => (a.createdAt !== b.createdAt ? b.createdAt - a.createdAt : a.sha256 < b.sha256 ? -1 : a.sha256 > b.sha256 ? 1 : 0))
  }

  /** Hashes Media hides (every live note an emoji note) and the saved emoji copies (net/emoji-notes.js). */
  emojiOnly() { return emojiOnlyHashes(this.notes.values()) }
  emojiCopies() { return emojiCopies(this.notes.values()) }

  #seen(at) {
    if (this.newestSeen === undefined || at > this.newestSeen) this.newestSeen = at
  }
}
