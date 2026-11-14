// NAP-STORAGE for napplets, in the shell's IndexedDB: one database per account ("nv-napplets:<pubkey>"), one row per
// (scope, key). A napplet has no storage of its own (its frame's origin is null) and never sees another's scope:
// dispatch.js picks the scope from who is asking (instance = publisher:dTag:hash, shared = publisher:dTag).
export function idbNappletStorage(account, idb = globalThis.indexedDB) {
  let dbp
  const db = () => (dbp ??= new Promise((resolve, reject) => {
    const r = idb.open(`nv-napplets:${account}`, 1)
    r.onupgradeneeded = () => r.result.createObjectStore("kv")
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  }))
  const tx = async (mode, fn) => {
    const d = await db()
    return new Promise((resolve, reject) => {
      const t = d.transaction("kv", mode), out = fn(t.objectStore("kv"))
      t.oncomplete = () => resolve(out?.result)
      t.onerror = () => reject(t.error)
    })
  }
  return {
    get: (scope, key) => tx("readonly", s => s.get([scope, key])),
    set: (scope, key, value) => tx("readwrite", s => s.put(value, [scope, key])),
    remove: (scope, key) => tx("readwrite", s => s.delete([scope, key])),
    keys: async scope => (await tx("readonly", s => s.getAllKeys(IDBKeyRange.bound([scope, ""], [scope, "￿"])))).map(k => k[1]),
    /** Every key one scope holds (Remove in the Apps pane, catalog.js removeApp). Exactly that scope: a prefix range
     *  would also wipe "pub:foobar" when removing "pub:foo". Arrays sort after every string, so [scope, []] ends it. */
    clear: scope => tx("readwrite", s => s.delete(IDBKeyRange.bound([scope, ""], [scope, []]))),
  }
}

/** The installed apps' bytes (Apps pane, P3), per account: hash -> index.html text. Kept so an installed app opens
 *  without a server; checked against its hash again every time it mounts (runtime.js). */
export function idbArtifacts(account, idb = globalThis.indexedDB) {
  let dbp
  const db = () => (dbp ??= new Promise((resolve, reject) => {
    const r = idb.open(`nv-napplet-apps:${account}`, 1)
    r.onupgradeneeded = () => r.result.createObjectStore("html")
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  }))
  const tx = async (mode, fn) => {
    const d = await db()
    return new Promise((resolve, reject) => {
      const t = d.transaction("html", mode), out = fn(t.objectStore("html"))
      t.oncomplete = () => resolve(out?.result)
      t.onerror = () => reject(t.error)
    })
  }
  return {
    get: hash => tx("readonly", s => s.get(hash)),
    put: (hash, html) => tx("readwrite", s => s.put(html, hash)),
    remove: hash => tx("readwrite", s => s.delete(hash)),
  }
}
