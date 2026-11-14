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
    /** Every key a napplet line left (Remove in the Apps pane, P3). */
    clear: scope => tx("readwrite", s => s.delete(IDBKeyRange.bound([scope, ""], [scope + "￿", ""]))),
  }
}
