// The follows' contact lists (kind 3) kept in this browser, so the web of trust (wot.js followLists) is there at once
// on the next page load instead of downloading every follow's list again: 1,054 lists were ~60 MB on each reload.
// Only who each list follows is kept, 32 bytes a person, not the signed event (a list's petnames and relay hints make
// it ~2x bigger and nothing here reads them). Haven /feed can't hold them: it only takes feed notes (OnlyFeedKinds).
// Named so sign-out's store wipe takes it (haven/vault.js storeNames).
import { loadSession } from "../session.js"

const HEX64 = /^[0-9a-f]{64}$/

export const wotDbName = pubkey => `haven:${pubkey}:wotlists`
const LOAD_BATCH = 40

/**
 * A follow's contact list as this page holds it: who they follow and when, nothing else. A relay's kind 3 carries
 * petnames, relay hints and a content blob, and held whole for 1,040 follows it was most of the page's heap once the
 * lists were read (Tidy's audit 11-20, W8). `ps` is the followed keys, once each, as shared strings (interner): the
 * same person on 300 lists is one string. `tags` is made on each read, for the readers that walk a kind 3's p tags
 * (Popular, Messages' trust, For you, the web gate...), so they need not change; only p tags are kept.
 */
export class FollowList {
  constructor(pubkey, created_at, ps) {
    this.kind = 3
    this.pubkey = pubkey
    this.created_at = created_at
    this.ps = ps
  }
  get tags() { return this.ps.map(pk => ["p", pk]) }
}

/** One copy of each key string: -> intern(s) giving back the first string equal to s. */
export function interner() {
  const seen = new Map()
  return s => { const had = seen.get(s); if (had !== undefined) return had; seen.set(s, s); return s }
}
const same = s => s

/** A relay's kind 3 (or a FollowList) as a FollowList: valid p keys only, once each. */
export function compactList(ev, intern = same) {
  if (ev instanceof FollowList) return ev
  const seen = new Set(), ps = []
  for (const t of ev.tags ?? []) {
    if (t[0] !== "p" || typeof t[1] !== "string" || t[1].length !== 64 || !HEX64.test(t[1]) || seen.has(t[1])) continue
    seen.add(t[1]); ps.push(intern(t[1]))
  }
  return new FollowList(ev.pubkey, ev.created_at, ps)
}

/** A kind 3 as kept: { pubkey, created_at, ps: Uint8Array of 32-byte keys }. A follow whose list the relay didn't
 *  have is kept as { pubkey, missed: unix seconds }. */
export function pack(ev) {
  const ps = ev instanceof FollowList ? ev.ps : compactList(ev).ps
  const bytes = new Uint8Array(ps.length * 32)
  ps.forEach((pk, i) => { for (let j = 0; j < 32; j++) bytes[i * 32 + j] = parseInt(pk.substr(j * 2, 2), 16) })
  return { pubkey: ev.pubkey, created_at: ev.created_at, ps: bytes }
}

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"))
/** Back to the shape followLists hands out: a FollowList, its keys shared through `intern`. */
export function unpack({ pubkey, created_at, ps }, intern = same) {
  const out = []
  for (let i = 0; i < ps.length; i += 32) {
    let pk = ""
    for (let j = i; j < i + 32; j++) pk += HEX[ps[j]]
    out.push(intern(pk))
  }
  return new FollowList(pubkey, created_at, out)
}

/**
 * -> { load(intern): { lists: Map(pk -> FollowList), misses: Map(pk -> unix seconds), checkedAt }, save(events, checkedAt, misses, missedAt) },
 * or a store that keeps nothing where
 * there is no IndexedDB (node, the tests). `checkedAt` (unix seconds) is when the relays were last asked for newer
 * lists; followLists asks again `since` then. A failed read or write keeps nothing: the lists are only a cache.
 */
// One store (one connection) per account for the page: sign-out's delete reaches it as a versionchange.
const stores = new Map()
export const emptyKept = () => ({ lists: new Map(), misses: new Map(), checkedAt: 0 })

// Who is signed in now: a store whose account has signed out must not open (opening creates the database again).
const signedInNow = () => globalThis.localStorage ? loadSession(globalThis.localStorage)?.pubkey : undefined

export function wotStore(pubkey, idb = globalThis.indexedDB, signedIn = signedInNow) {
  if (!idb || !pubkey) return { load: async () => emptyKept(), save: async () => {}, count: async () => 0, clear: async () => {} }
  if (idb === globalThis.indexedDB && stores.has(pubkey)) return stores.get(pubkey)
  const store = openStore(pubkey, idb, signedIn)
  if (idb === globalThis.indexedDB) stores.set(pubkey, store)
  return store
}

function openStore(pubkey, idb, signedIn) {
  const none = emptyKept
  // `gone` once the database is deleted under us (sign-out, here or in another tab): a save still in flight then must
  // not create it again with the signed-out account's follows in it.
  let db = null, gone = false, existed = false
  const open = () => db ??= new Promise((resolve, reject) => {
    if (gone) return reject(new Error("store deleted"))
    // Signed out before the first open (sign-out's wipe found no database to delete, so no versionchange came).
    if (signedIn() !== pubkey) { gone = true; return reject(new Error("signed out")) }
    const req = idb.open(wotDbName(pubkey), 1)
    req.onupgradeneeded = () => {
      if (existed) { gone = true; req.transaction.abort(); return } // it was there before: this is a re-create
      req.result.createObjectStore("lists", { keyPath: "pubkey" }); req.result.createObjectStore("meta")
    }
    req.onsuccess = () => {
      existed = true
      req.result.onversionchange = () => { req.result.close(); db = null; gone = true }
      resolve(req.result)
    }
    req.onerror = () => { db = null; reject(req.error) }
  })
  const tx = (mode, f) => open().then(d => new Promise((resolve, reject) => {
    const t = d.transaction(["lists", "meta"], mode)
    const out = f(t.objectStore("lists"), t.objectStore("meta"))
    t.oncomplete = () => resolve(out)
    t.onerror = t.onabort = () => reject(t.error)
  }))
  return {
    // LOAD_BATCH rows a transaction, with a pause between, rather than one getAll: reading ~20 MB of lists back in one
    // go held the page ~0.5 s, and a reload's first note waited behind it.
    async load(intern) {
      try {
        const lists = new Map(), misses = new Map()
        let checked = 0, after = null
        for (;;) {
          let rows = []
          await tx("readonly", (store, meta) => {
            store.getAll(after === null ? null : IDBKeyRange.lowerBound(after, true), LOAD_BATCH).onsuccess = e => { rows = e.target.result ?? [] }
            if (after === null) meta.get("checkedAt").onsuccess = e => { checked = e.target.result ?? 0 }
          })
          for (const r of rows) if (r.ps) lists.set(r.pubkey, unpack(r, intern)); else misses.set(r.pubkey, r.missed)
          if (rows.length < LOAD_BATCH) break
          after = rows.at(-1).pubkey
          await new Promise(r => setTimeout(r, 0))
        }
        return { lists, misses, checkedAt: checked }
      } catch { return none() }
    },
    /** How many follows' lists (and known misses) are kept: the dashboard's Cache row. 0 when it can't tell. */
    async count() {
      try { let n = 0; await tx("readonly", store => { store.count().onsuccess = e => { n = e.target.result ?? 0 } }); return n } catch { return 0 }
    },
    /** Empties the kept lists and the last-check time (the dashboard's Clear cache): the next load downloads them
     *  again. The open connection stays, so this page keeps working. */
    async clear() {
      try { await tx("readwrite", (store, meta) => { store.clear(); meta.clear() }) } catch {}
    },
    async save(events, checkedAt, misses = [], missedAt = checkedAt) {
      try {
        await tx("readwrite", (lists, meta) => {
          for (const ev of events) lists.put(pack(ev))
          // followLists only names follows it holds no list for: a miss never overwrites a kept list.
          for (const pk of misses) lists.put({ pubkey: pk, missed: missedAt })
          if (checkedAt != null) meta.put(checkedAt, "checkedAt")
        })
      } catch {}
    },
  }
}
