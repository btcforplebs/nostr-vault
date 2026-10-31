// The inbox kept between reloads and tabs (Logen, 2026-10-31): without it every reload asked the signer to open every
// message again, two requests each. What is kept is the opened messages, and the ids of wraps found not to be the
// user's, in chunks the signer encrypts to the user's own key (NIP-44, as a self-copy's seal is): never plain text.
// A reload asks the signer once per chunk instead of twice per message, and only that signer can open them.
// - Where: localStorage "nv-dm-cache:<pubkey>", one per account. Sign-out (haven/vault.js accountKeys: every key ending
//   ":<pubkey>"), removing the account and Reset Everything (net/reset-all.js isAppKey) delete it.
// - A chunk that doesn't open (the signer refused or didn't answer, or it isn't what was written) is dropped. Its
//   messages are opened from their wraps again as if never seen, and kept anew.
// - Written only while this account is still the signed-in one: a tab still running after another tab signed out
//   doesn't write it back.
import { loadSession } from "../session.js"

const KEY = "nv-dm-cache"
const HEX64 = /^[0-9a-f]{64}$/
/**
 * A chunk's size, counted as it travels inside a JSON string (quotes and backslashes escaped). NIP-44 takes at most
 * 65,535 bytes. Through a bunker (NIP-46) a chunk rides inside a request, and its ciphertext comes back in the answer,
 * each NIP-44 again in a kind 24133 that relays cap at about 64 KB: there a chunk must stay small enough that both
 * the request and the answer fit (Tron, #1376). test/dm-cache.test.mjs measures it with the real BunkerSigner.
 */
export const CHUNK_BYTES = { nip46: 24_000, other: 60_000 }
export const chunkBytesFor = method => (method === "nip46" ? CHUNK_BYTES.nip46 : CHUNK_BYTES.other)
/** At most this many chunks (about 1.3 MB stored); past it the oldest goes, and its messages are opened again. */
export const MAX_CHUNKS = 16
/** How long a chunk gets to open before it counts as failed: the inbox doesn't wait on a signer that's away. */
export const OPEN_WAIT = 10_000
/** New messages are written this long after the last one arrived, so a burst is one signer request. */
export const WRITE_AFTER = 1500

export const cacheKey = me => `${KEY}:${me}`
const bytes = s => new TextEncoder().encode(JSON.stringify(s)).length // as it travels in a JSON string
const row = m => [m.id, m.from, m.peer, m.content, m.at, m.legacy ? 1 : 0]
const fromRow = r => Array.isArray(r) && HEX64.test(r[0] ?? "") && HEX64.test(r[1] ?? "") && HEX64.test(r[2] ?? "") && typeof r[3] === "string" && Number.isFinite(r[4])
  ? { id: r[0], from: r[1], peer: r[2], content: r[3], at: r[4], legacy: r[5] === 1 } : null
const chunkText = (me, c) => JSON.stringify({ v: 1, me, m: c.m, j: c.j })
const timeout = ms => new Promise((_, no) => setTimeout(() => no(new Error("timed out")), ms))

function readStored(storage, me) {
  try {
    const s = JSON.parse(storage?.getItem(cacheKey(me)) ?? "null")
    return s?.v === 1 && Array.isArray(s.chunks) ? s.chunks.filter(c => typeof c === "string") : []
  } catch { return [] }
}

/**
 * One account's kept inbox. `crypto` is the session's (dms.js cryptoFor): encrypt / decrypt with NIP-44.
 * restore() -> { messages, junk } from what was kept; add(message) and junk(id) keep more, written shortly after.
 */
export function dmCache(me, crypto, { chunkBytes = CHUNK_BYTES.other, storage = globalThis.localStorage, wait = OPEN_WAIT, writeAfter = WRITE_AFTER, signedIn = () => !!storage && loadSession(storage)?.pubkey === me } = {}) {
  let sealed = [] // full chunks, as stored
  let tail = { m: [], j: [] } // the last chunk, still filling, in memory only
  const known = new Set() // ids in the cache
  let timer = null
  let writing = Promise.resolve()
  let dirty = false

  const restore = async () => {
    const stored = readStored(storage, me)
    const opened = await Promise.all(stored.map(ct => Promise.race([crypto.decrypt(me, ct), timeout(wait)]).then(text => {
      const c = JSON.parse(text)
      if (c?.v !== 1 || c.me !== me || !Array.isArray(c.m) || !Array.isArray(c.j)) return null
      return { ct, m: c.m.map(fromRow).filter(Boolean), j: c.j.filter(id => HEX64.test(id ?? "")) }
    }).catch(() => null)))
    const good = opened.filter(Boolean)
    // Kept while this was opening (a live message): it goes after what was stored, once.
    const inStore = new Set(good.flatMap(c => [...c.m.map(m => m.id), ...c.j]))
    const early = { m: tail.m.filter(r => !inStore.has(r[0])), j: tail.j.filter(id => !inStore.has(id)) }
    const messages = [], junk = []
    for (const c of good) {
      for (const m of c.m) if (!known.has(m.id)) { known.add(m.id); messages.push(m) }
      for (const id of c.j) if (!known.has(id)) { known.add(id); junk.push(id) }
    }
    // The last chunk keeps filling; the others stay as they were stored. A chunk that didn't open is dropped.
    const last = good.at(-1)
    if (last && last === opened.at(-1) && bytes(chunkText(me, { m: last.m.map(row), j: last.j })) < chunkBytes) {
      sealed = good.slice(0, -1).map(c => c.ct)
      tail = { m: [...last.m.map(row), ...early.m], j: [...last.j, ...early.j] }
    } else { sealed = good.map(c => c.ct); tail = early }
    if (good.length !== stored.length || early.m.length || early.j.length) { dirty = true; schedule() }
    return { messages, junk }
  }

  // Seal what's in `tail`: full chunks become sealed ones, the rest is the new last chunk. One signer request per chunk.
  const write = async () => {
    if (!dirty || !signedIn()) return
    dirty = false
    const full = []
    let cur = { m: [], j: [] }
    for (const r of tail.m) {
      if (cur.m.length && bytes(chunkText(me, { m: [...cur.m, r], j: cur.j })) > chunkBytes) { full.push(cur); cur = { m: [], j: [] } }
      cur.m.push(r)
    }
    for (const id of tail.j) {
      if (bytes(chunkText(me, { m: cur.m, j: [...cur.j, id] })) > chunkBytes) { full.push(cur); cur = { m: [], j: [] } }
      cur.j.push(id)
    }
    try {
      const done = await Promise.all(full.map(c => crypto.encrypt(me, chunkText(me, c))))
      const last = cur.m.length || cur.j.length ? await crypto.encrypt(me, chunkText(me, cur)) : null
      if (!signedIn()) return
      sealed = [...sealed, ...done].slice(-(MAX_CHUNKS - 1))
      tail = cur
      const chunks = last ? [...sealed, last] : sealed
      if (!chunks.length) { storage.removeItem(cacheKey(me)); return }
      for (let n = chunks.length; n >= 1; n--) {
        const keep = chunks.slice(-n)
        try { storage.setItem(cacheKey(me), JSON.stringify({ v: 1, chunks: keep })); sealed = last ? keep.slice(0, -1) : keep; return } catch {} // full: drop the oldest
      }
    } catch { dirty = true } // the signer didn't encrypt: try with the next change
  }
  const schedule = () => {
    clearTimeout(timer)
    timer = setTimeout(() => { timer = null; writing = writing.then(write, write) }, writeAfter)
  }

  return {
    me,
    restore,
    /** Keep an opened message (not a pending or failed bubble). One too big for a chunk isn't kept. */
    add(m) {
      if (!m?.id || m.pending || m.failed || known.has(m.id) || !HEX64.test(m.id)) return
      const r = row(m)
      if (bytes(chunkText(me, { m: [r], j: [] })) > chunkBytes) return
      known.add(m.id); tail.m.push(r); dirty = true; schedule()
    },
    /** Keep the id of a wrap that isn't the user's, so it isn't asked about again. */
    junk(id) {
      if (!HEX64.test(id ?? "") || known.has(id)) return
      known.add(id); tail.j.push(id); dirty = true; schedule()
    },
    /** For tests: write now. */
    flush() { clearTimeout(timer); timer = null; writing = writing.then(write, write); return writing },
    /** Stop writing (another account, or signed out). */
    close() { clearTimeout(timer); timer = null; dirty = false },
  }
}
