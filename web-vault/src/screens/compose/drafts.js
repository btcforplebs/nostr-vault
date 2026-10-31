// Drafts: one per account and per target (a new note, a reply or quote to one note, an article, a poll), in an IndexedDB database named
// like Haven's own, "haven:<pubkey>:drafts", so sign-out's wipe (vault.js storeNames) deletes it with the rest.
// Each write is its own short connection, and one asked to close for a delete closes, so it never blocks sign-out.
export const draftKey = target => (target ? `${target.mode}:${target.id}` : "new")

export function idbDrafts(pubkey, idb = globalThis.indexedDB) {
  const run = (mode, op) => new Promise((resolve, reject) => {
    const req = idb.open(`haven:${pubkey}:drafts`, 1)
    req.onupgradeneeded = () => req.result.createObjectStore("drafts")
    req.onerror = () => reject(req.error)
    req.onsuccess = () => {
      const db = req.result
      db.onversionchange = () => db.close()
      const tx = db.transaction("drafts", mode)
      const r = op(tx.objectStore("drafts"))
      tx.oncomplete = () => { db.close(); resolve(r?.result) }
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error) }
    }
  })
  return {
    get: key => run("readonly", s => s.get(key)),
    put: (key, value) => run("readwrite", s => s.put(value, key)),
    delete: key => run("readwrite", s => s.delete(key)),
  }
}
