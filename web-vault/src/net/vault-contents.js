// What the vault holds, grouped the way the Vault tab names things (iPhone Models/VaultContents.swift and
// VaultContentsModel.swift). Every number is a NIP-45 COUNT one of this browser's Haven routes gave: "/", "/inbox",
// "/private" and "/chat", summed. The feed cache is left out, as on the phone: it holds other people's notes.
// Media files are the Blossom blobs Haven keeps in IndexedDB (haven-go/blobfs_wasm.go), typed by their first bytes.

export const GROUPS = [
  { id: "notes", title: "Notes", kinds: [1, 6, 1111, 1068] },
  { id: "articles", title: "Articles", kinds: [30023, 30024] },
  { id: "highlights", title: "Highlights", kinds: [9802] },
  { id: "reactions", title: "Reactions", kinds: [7] },
  // A zap receipt is signed by the payer's wallet server and a gift wrap by a throwaway key: "yours" means nothing.
  { id: "zaps", title: "Zaps", kinds: [9734, 9735], countsYours: false },
  { id: "messages", title: "Messages", kinds: [4, 1059], countsYours: false },
  { id: "profile", title: "Profile and lists", kinds: [0, 3, 10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 10050, 10063, 30000, 30001, 30002, 30003] },
]

/** Kinds counted one by one beyond the groups, so "Other" can say what it holds. */
export const OTHER_KINDS = [5, 8, 9, 16, 20, 21, 22, 1063, 1311, 1808, 30008, 30009, 30030, 30078]
export const COUNTED_KINDS = [...GROUPS.flatMap(g => g.kinds), ...OTHER_KINDS]

const KIND_NAMES = {
  0: "Profile", 1: "Short notes", 3: "Follow list", 4: "Direct messages (old style)", 5: "Deletions", 6: "Reposts", 7: "Reactions",
  8: "Badge awards", 9: "Chat messages", 16: "Generic reposts", 20: "Pictures", 21: "Videos", 22: "Short videos",
  1059: "Gift-wrapped messages", 1063: "File details", 1068: "Polls", 1111: "Comments", 1311: "Live chat", 1808: "Audio tracks",
  9734: "Zap requests", 9735: "Zap receipts", 9802: "Highlights", 10000: "Mute list", 10001: "Pinned notes", 10002: "Relay list",
  10003: "Bookmarks", 10005: "Public chats", 10006: "Blocked relays", 10015: "Interests", 10030: "Emoji list",
  10050: "Message relays", 10063: "Media servers", 30000: "People lists", 30001: "Generic lists", 30002: "Relay sets",
  30003: "Bookmark sets", 30008: "Profile badges", 30009: "Badge definitions", 30023: "Articles", 30024: "Article drafts",
  30030: "Emoji sets", 30078: "App data",
}
export const kindName = k => (k == null ? "Kinds not listed" : KIND_NAMES[k] ?? `Kind ${k}`)

/** The vault's routes that answer COUNT (VaultContentsModel.relayURLs). */
export const COUNT_ROUTES = ["/", "/inbox", "/private", "/chat"]

/**
 * Every count the section shows, summed over `clients` (route clients with count(filter) -> number). Null unless every
 * route answered every question, as on the phone. -> { total, byKind: { kind: n }, yours: { group: n } } | null
 */
export async function countContents(clients, owner) {
  const asks = [["total", {}], ...COUNTED_KINDS.map(k => [`k${k}`, { kinds: [k] }]),
    ...GROUPS.filter(g => g.countsYours !== false).map(g => [`y-${g.id}`, { kinds: g.kinds, authors: [owner] }])]
  const sums = {}
  try {
    for (const client of clients) {
      const answers = await Promise.all(asks.map(([, f]) => client.count(f)))
      answers.forEach((n, i) => {
        if (!Number.isFinite(n)) throw new Error("no count")
        sums[asks[i][0]] = (sums[asks[i][0]] ?? 0) + n
      })
    }
  } catch { return null }
  const byKind = {}, yours = {}
  for (const [k, v] of Object.entries(sums)) {
    if (/^k\d+$/.test(k)) byKind[k.slice(1)] = v
    if (k.startsWith("y-")) yours[k.slice(2)] = v
  }
  return { total: sums.total ?? 0, byKind, yours }
}

const kindRows = (kinds, byKind) => kinds.map(k => ({ kind: k, count: byKind[k] ?? 0 })).filter(r => r.count > 0).sort((a, b) => b.count - a.count)

/** The section's rows, in the phone's order, empty ones left out (VaultContents.groupRows).
 *  -> [{ id, title, count, yours: n | null, kinds: [{ kind, count }] }] */
export function groupRows({ total, byKind, yours }) {
  const named = GROUPS.map(g => ({ id: g.id, title: g.title, count: g.kinds.reduce((n, k) => n + (byKind[k] ?? 0), 0),
    yours: g.countsYours === false ? null : yours[g.id] ?? 0, kinds: kindRows(g.kinds, byKind) }))
  const namedTotal = named.reduce((n, r) => n + r.count, 0)
  const other = kindRows(OTHER_KINDS, byKind)
  const unlisted = Math.max(0, total - namedTotal - other.reduce((n, r) => n + r.count, 0))
  if (unlisted > 0) { other.push({ kind: null, count: unlisted }); other.sort((a, b) => b.count - a.count) }
  return [...named, { id: "other", title: "Other", count: Math.max(0, total - namedTotal), yours: null, kinds: other }].filter(r => r.count > 0)
}

/** Bytes as the phone's ByteCountFormatter (file style: 1000 based), "None" for nothing. */
export function sizeText(bytes) {
  if (!(bytes > 0)) return "None"
  if (bytes < 1000) return `${bytes} bytes`
  const units = ["KB", "MB", "GB", "TB"]
  let v = bytes / 1000, i = 0
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++ }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1).replace(/\.0$/, "")} ${units[i]}`
}

/** A file's type by its first bytes, as the phone types Blossom files (detectMimeFromBytes). -> "image" | "video" | "audio" | "other" */
export function mediaBucket(b) {
  if (!b || b.length < 4) return "other"
  const at = (i, ...xs) => xs.every((x, j) => b[i + j] === x)
  const ascii = (i, s) => [...s].every((c, j) => b[i + j] === c.charCodeAt(0))
  if (at(0, 0xff, 0xd8, 0xff) || at(0, 0x89, 0x50, 0x4e, 0x47) || ascii(0, "GIF8") || (ascii(0, "RIFF") && ascii(8, "WEBP"))) return "image"
  if (ascii(4, "ftyp")) return /^(avif|avis|heic|heix|mif1)/.test(String.fromCharCode(...b.slice(8, 12))) ? "image" : /^M4A/.test(String.fromCharCode(...b.slice(8, 11))) ? "audio" : "video"
  if (at(0, 0x1a, 0x45, 0xdf, 0xa3)) return "video" // webm / matroska
  if (ascii(0, "ID3") || at(0, 0xff, 0xfb) || at(0, 0xff, 0xf3) || ascii(0, "OggS") || ascii(0, "fLaC") || (ascii(0, "RIFF") && ascii(8, "WAVE"))) return "audio"
  if (ascii(0, "<svg") || ascii(0, "<?xm")) return "image"
  return "other"
}

export const MEDIA_BUCKETS = [["image", "Images"], ["video", "Videos"], ["audio", "Audio"], ["other", "Other"]]

/**
 * The Blossom files this browser's vault keeps (IndexedDB "haven:<pubkey>:blobs", one record per blob), counted and
 * sized by type. Values are read one at a time; only their first bytes are looked at. `idb` is for tests.
 * -> { count, size, buckets: { image: { count, size }, ... } } | null when there is no store
 */
export async function scanMedia(pubkey, idb = globalThis.indexedDB) {
  if (!idb) return null
  const name = `haven:${pubkey}:blobs`
  const known = typeof idb.databases === "function" ? (await idb.databases().catch(() => null))?.some(d => d.name === name) : true
  const empty = () => ({ count: 0, size: 0, buckets: Object.fromEntries(MEDIA_BUCKETS.map(([k]) => [k, { count: 0, size: 0 }])) })
  if (known === false) return empty()
  const db = await new Promise((res, rej) => { const r = idb.open(name); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); r.onupgradeneeded = () => r.transaction.abort() }).catch(() => null)
  if (!db) return empty()
  try {
    if (!db.objectStoreNames.contains("blobs")) return empty()
    const out = empty()
    await new Promise((res, rej) => {
      const req = db.transaction("blobs").objectStore("blobs").openCursor()
      req.onerror = () => rej(req.error)
      req.onsuccess = () => {
        const c = req.result
        if (!c) return res()
        const bytes = toBytes(c.value)
        const k = mediaBucket(bytes?.subarray(0, 16))
        out.count++; out.size += bytes?.byteLength ?? 0
        out.buckets[k].count++; out.buckets[k].size += bytes?.byteLength ?? 0
        c.continue()
      }
    })
    return out
  } finally { db.close() }
}
const toBytes = v => (v instanceof Uint8Array ? v : v instanceof ArrayBuffer ? new Uint8Array(v) : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : null)

/** Every blob as { name, bytes }, for Back up media. Names are the blob paths' last part (the sha256). */
export async function readMedia(pubkey, idb = globalThis.indexedDB) {
  const db = await new Promise((res, rej) => { const r = idb.open(`haven:${pubkey}:blobs`); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); r.onupgradeneeded = () => r.transaction.abort() }).catch(() => null)
  if (!db) return []
  try {
    if (!db.objectStoreNames.contains("blobs")) return []
    return await new Promise((res, rej) => {
      const out = [], req = db.transaction("blobs").objectStore("blobs").openCursor()
      req.onerror = () => rej(req.error)
      req.onsuccess = () => { const c = req.result; if (!c) return res(out); const b = toBytes(c.value); if (b) out.push({ name: String(c.key).split("/").pop(), data: b }); c.continue() }
    })
  } finally { db.close() }
}
