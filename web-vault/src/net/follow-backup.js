// Following Backup (iPhone FollowingBackupView, FollowingSnapshot, FeedService.restoreContactList): copies of your
// follow list (kind 3) kept in this browser, older lists found on your relays, what changed since each, and putting
// one back. Restore publishes the old list as your follow list now, so it is only ever done after the user confirms.
import { pool, publishRelays, uniq, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { followsOf, findLatestList } from "./follows.js"
import { verifyEvent } from "nostr-tools/pure"

export const MAX_SNAPSHOTS = 50
const now = () => Math.floor(Date.now() / 1000)
const pick = ({ id, pubkey, created_at, kind, tags, content, sig }) => ({ id, pubkey, created_at, kind, tags, content, sig })
/** A relay can send anything and Restore republishes it as yours: only your own, validly signed kind 3 counts. */
export const ownList = (ev, me) => ev?.kind === 3 && ev.pubkey === me && Array.isArray(ev.tags) && (() => { try { return verifyEvent(pick(ev)) } catch { return false } })()

// ---- Snapshots in this browser ----

/** Named so sign-out's store wipe takes it (haven/vault.js storeNames). */
export const backupDbName = pubkey => `haven:${pubkey}:followbackup`

/** -> { all(): [snapshot] newest first, put(snapshot), remove(id) }. A snapshot is the signed kind 3 + `savedAt`. */
export function snapshotStore(pubkey, idb = globalThis.indexedDB) {
  const open = () => new Promise((resolve, reject) => {
    const req = idb.open(backupDbName(pubkey), 1)
    req.onupgradeneeded = () => req.result.createObjectStore("snapshots", { keyPath: "id" })
    req.onsuccess = () => { req.result.onversionchange = () => req.result.close(); resolve(req.result) }
    req.onerror = () => reject(req.error)
  })
  const run = (mode, f) => open().then(db => new Promise((resolve, reject) => {
    const tx = db.transaction("snapshots", mode), req = f(tx.objectStore("snapshots"))
    tx.oncomplete = () => { db.close(); resolve(req.result) }
    tx.onerror = () => { db.close(); reject(tx.error) }
  }))
  return {
    all: async () => ((await run("readonly", s => s.getAll())) ?? []).sort((a, b) => b.created_at - a.created_at),
    put: snap => run("readwrite", s => s.put(snap)),
    remove: id => run("readwrite", s => s.delete(id)),
  }
}

/**
 * Keep `list` (a kind 3) as a snapshot unless it's already kept or empty, then trim to MAX_SNAPSHOTS, oldest first.
 * -> whether it was added
 */
export async function keepSnapshot(store, list, me) {
  if (!ownList(list, me) || !followsOf(list).length) return false
  const all = await store.all()
  if (all.some(s => s.id === list.id)) return false
  await store.put({ ...pick(list), savedAt: now() })
  for (const old of [...all, list].sort((a, b) => b.created_at - a.created_at).slice(MAX_SNAPSHOTS)) await store.remove(old.id)
  return true
}

// ---- Older lists on the relays ----

/** Every list of yours the relays still hold (most keep only the newest; some keep history), newest first. */
export async function scanRelays(me, relays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...relays, ...PROFILE_RELAYS]), { kinds: [3], authors: [me], limit: 50 }, { maxWait: 10_000 })
  const by = new Map()
  for (const ev of evs) if (!by.has(ev.id) && ownList(ev, me)) by.set(ev.id, pick(ev))
  return [...by.values()].sort((a, b) => b.created_at - a.created_at)
}

/** Against the list you have now: who the old one has that you no longer follow, and who you've added since. */
export function diffLists(current, old) {
  const now = new Set(followsOf(current)), then = new Set(followsOf(old))
  return { removed: [...then].filter(p => !now.has(p)), added: [...now].filter(p => !then.has(p)) }
}

// ---- Restore ----

/**
 * Your newest follow list, as Restore will replace it. Refused when your relays can't be heard or none of them has a
 * list (wipeGuard's first two rules): with no list to keep first, a restore couldn't be undone.
 * -> the newest kind 3
 */
export async function restoreBase({ ctx, ask }) {
  const me = ctx.session.pubkey
  const relays = uniq([...ctx.account.relays.read, ...ctx.account.relays.write])
  const { base, asked, answered, netFound } = await findLatestList({ vault: ctx.vault, pubkey: me, relays, ask })
  if (!netFound && !(asked > 0 && answered * 2 > asked))
    throw new Error("Not enough of your relays answered to know your newest follow list, so nothing was changed. Try again when they're reachable.")
  if (!base) throw new Error("Your follow list wasn't found on your relays, so nothing was changed. Try again when they answer.")
  return base
}

/**
 * Publish `old`'s follows as your follow list, signed now. `shown` is the list the user saw the change against
 * (restoreBase): if your newest list is another one by now, nothing is published. The newest list is kept as a
 * snapshot first, so a restore can itself be undone, and nothing is published if it can't be kept. The restored list
 * keeps the newest one's content (where many apps keep your relays) and is dated after it so no relay keeps the newer one.
 * -> { event, relays: [{ url, ok, message }] }
 */
export async function restoreList({ ctx, old, shown, store, ask }) {
  const me = ctx.session.pubkey
  if (!ownList(old, me)) throw new Error("That list isn't one you signed, so it can't be restored.")
  if (!followsOf(old).length) throw new Error("That list follows nobody, so it wasn't restored.")
  const base = await restoreBase({ ctx, ask })
  if (shown && base.id !== shown.id) throw new Error("Your follow list changed since you looked, so nothing was changed. Check the changes again.")
  try {
    await keepSnapshot(store, base, me)
    if (followsOf(base).length && !(await store.all()).some(s => s.id === base.id)) throw new Error("it isn't a list you signed")
  } catch (e) {
    throw new Error(`Your current list couldn't be saved in this browser first (${e?.message ?? e}), so nothing was changed.`)
  }
  const template = { kind: 3, created_at: Math.max(now(), base.created_at + 1), tags: old.tags.map(t => [...t]), content: base.content ?? "" }
  const event = checkSigned(await ctx.signer.signEvent(template), template, me)
  const { network } = publishRelays(ctx.account.relays.write)
  const results = await Promise.allSettled(pool.publish(network, event))
  const out = results.map((r, i) => ({ url: network[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) }))
  if (!out.some(r => r.ok)) throw new Error(`No relay took it (0 of ${network.length}), so nothing changed.`)
  const stored = await ctx.vault.outbox.event(event)
  if (!stored.ok && !/^duplicate:/.test(stored.message)) throw new Error(`Sent, but Haven refused the follow list: ${stored.message}`)
  return { event, relays: out }
}
