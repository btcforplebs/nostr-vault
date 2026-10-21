// Recently Deleted (iPhone RecentlyDeletedSettingsView, DeletedPost, NostrService+DeletedPosts): a copy of each post
// deleted from this browser, kept 30 days per account, so it can be posted again. Nostr has no undo: once the kind 5
// is out, relays that honour it (this browser's own Haven included) refuse the old id for good, so Un-delete posts the
// same kind, text and tags as a new post, stamped now. Likes and replies on the old post stay with the old id.
import { publishAction } from "./actions.js"

export const KEEP_DAYS = 30
export const UNDELETE_NOTE = "Un-delete posts it again as a new post. Likes and replies on the old post don't come back."
const now = () => Math.floor(Date.now() / 1000)

/** Replaceable and addressable kinds get no copy: posted again with today's time, an old version would replace the
 *  newer one live at that address (DeletedPost.keepsCopy). */
export const keepsCopy = kind => !(kind === 0 || kind === 3 || (kind >= 10000 && kind < 20000) || (kind >= 30000 && kind < 40000))

/** What Un-delete signs: same kind, text and tags, without `nonce` (proof of work for the old id) and `expiration`
 *  (may have passed). DeletedPost.republishDraft. */
export const republishTemplate = (post, at = now()) => ({
  kind: post.kind, content: post.content, created_at: at,
  tags: (post.tags ?? []).filter(t => !["nonce", "expiration"].includes(t[0])).map(t => [...t]),
})

/** Named so sign-out's store wipe takes it (haven/vault.js PAGE_STORES). */
export const deletedDbName = pubkey => `haven:${pubkey}:deleted`

export function deletedStore(pubkey, idb = globalThis.indexedDB) {
  const open = () => new Promise((resolve, reject) => {
    const req = idb.open(deletedDbName(pubkey), 1)
    req.onupgradeneeded = () => req.result.createObjectStore("posts", { keyPath: "id" })
    req.onsuccess = () => { req.result.onversionchange = () => req.result.close(); resolve(req.result) }
    req.onerror = () => reject(req.error)
  })
  const run = (mode, f) => open().then(db => new Promise((resolve, reject) => {
    const tx = db.transaction("posts", mode), req = f(tx.objectStore("posts"))
    tx.oncomplete = () => { db.close(); resolve(req.result) }
    tx.onerror = () => { db.close(); reject(tx.error) }
  }))
  return {
    all: async () => (await run("readonly", s => s.getAll())) ?? [],
    put: post => run("readwrite", s => s.put(post)),
    remove: id => run("readwrite", s => s.delete(id)),
  }
}

const stores = new Map()
const storeFor = pubkey => { if (!stores.has(pubkey)) stores.set(pubkey, deletedStore(pubkey)); return stores.get(pubkey) }

/**
 * Called by deleteNote once the kind 5 went out: keep a copy of `note` if it's the account's own and of a kind that
 * gets one. -> whether a copy was kept
 */
export async function keepDeletedCopy(ctx, note, store = storeFor(ctx.session.pubkey), at = now()) {
  if (!note || note.pubkey !== ctx.session.pubkey || !keepsCopy(note.kind) || typeof note.content !== "string") return false
  const { id, pubkey, created_at, kind, tags = [], content, sig = "" } = note
  await store.put({ id, pubkey, created_at, kind, tags, content, sig, deletedAt: at })
  return true
}

/** The account's copies, newest delete first; ones past 30 days are dropped. */
export async function deletedPosts(pubkey, store = storeFor(pubkey), at = now()) {
  const all = await store.all()
  const out = []
  for (const p of all) {
    if (p.pubkey !== pubkey) continue
    if (at - p.deletedAt > KEEP_DAYS * 86400) { await store.remove(p.id).catch(() => {}); continue }
    out.push(p)
  }
  return out.sort((a, b) => b.deletedAt - a.deletedAt)
}

/** Post the copy again as a new post; the copy goes only once a relay took it. -> the new event */
export async function undelete(ctx, post, { store = storeFor(ctx.session.pubkey), publish = publishAction } = {}) {
  if (post.pubkey !== ctx.session.pubkey) throw new Error("This copy belongs to another account. Switch to it to post it again.")
  const { event } = await publish(ctx, republishTemplate(post))
  await store.remove(post.id)
  return event
}

export const forgetDeleted = (ctx, post, store = storeFor(ctx.session.pubkey)) => store.remove(post.id)
