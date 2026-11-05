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

/** Whether any relay other than this machine's own took the post: what "sent" means to every composer. */
export const reachedRelay = result => !!result?.relays?.some(r => !r.local && r.ok)

/**
 * After a send, for every composer (note, reply, quote, article, poll). Sent (a relay took it): the box is emptied,
 * nothing more is saved, and the saved draft is deleted before the caller moves on, so the next post can't start with
 * this one's text or attachments (a user's next note went out with the old photo, 2026-11-05: the composer closed
 * before its "empty box, delete the draft" save ran). Not sent: text and attachments stay, and so does the draft.
 * `stopSaving()` stops the composer's save-on-change; `clear()` empties its box. -> true when cleared
 */
export async function forgetIfSent(result, { stopSaving, clear, saving, drafts, key }) {
  if (!reachedRelay(result)) return false
  stopSaving()
  clear()
  await saving?.current
  await drafts.delete(key).catch(() => {})
  return true
}
