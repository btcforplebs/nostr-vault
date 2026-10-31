// The follows' contact lists (kind 3) kept in this browser, so the web of trust (wot.js followLists) is there at once
// on the next page load instead of downloading every follow's list again: 1,054 lists were ~60 MB on each reload.
// Only who each list follows is kept, 32 bytes a person, not the signed event (a list's petnames and relay hints make
// it ~2x bigger and nothing here reads them). Haven /feed can't hold them: it only takes feed notes (OnlyFeedKinds).
// Named so sign-out's store wipe takes it (haven/vault.js storeNames).
import { loadSession } from "../session.js"

const HEX64 = /^[0-9a-f]{64}$/

export const wotDbName = pubkey => `haven:${pubkey}:wotlists`
const LOAD_BATCH = 40

/** A kind 3 as kept: { pubkey, created_at, ps: Uint8Array of 32-byte keys }. A follow whose list the relay didn't
 *  have is kept as { pubkey, missed: unix seconds }. */
export function pack(ev) {
  const ps = [...new Set((ev.tags ?? []).filter(t => t[0] === "p" && HEX64.test(t[1] ?? "")).map(t => t[1]))]
  const bytes = new Uint8Array(ps.length * 32)
  ps.forEach((pk, i) => { for (let j = 0; j < 32; j++) bytes[i * 32 + j] = parseInt(pk.substr(j * 2, 2), 16) })
  return { pubkey: ev.pubkey, created_at: ev.created_at, ps: bytes }
}

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"))
/** Back to the shape followLists hands out: a kind 3 with only its `p` tags. */
export function unpack({ pubkey, created_at, ps }) {
  const tags = []
  for (let i = 0; i < ps.length; i += 32) {
    let pk = ""
    for (let j = i; j < i + 32; j++) pk += HEX[ps[j]]
    tags.push(["p", pk])
  }
  return { kind: 3, pubkey, created_at, tags }
}

/**
 * -> { load(): { lists: Map(pk -> kind 3), misses: Map(pk -> unix seconds), checkedAt }, save(events, checkedAt, misses, missedAt) },
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
  if (!idb || !pubkey) return { load: async () => emptyKept(), save: async () => {} }
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
    async load() {
      try {
        const lists = new Map(), misses = new Map()
        let checked = 0, after = null
        for (;;) {
          let rows = []
          await tx("readonly", (store, meta) => {
            store.getAll(after === null ? null : IDBKeyRange.lowerBound(after, true), LOAD_BATCH).onsuccess = e => { rows = e.target.result ?? [] }
            if (after === null) meta.get("checkedAt").onsuccess = e => { checked = e.target.result ?? 0 }
          })
          for (const r of rows) if (r.ps) lists.set(r.pubkey, unpack(r)); else misses.set(r.pubkey, r.missed)
          if (rows.length < LOAD_BATCH) break
          after = rows.at(-1).pubkey
          await new Promise(r => setTimeout(r, 0))
        }
        return { lists, misses, checkedAt: checked }
      } catch { return none() }
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
