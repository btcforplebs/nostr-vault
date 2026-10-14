// People the user blocked: their kind 10000 mute list (NIP-51), the same list the iPhone app writes when you block
// someone there. A block hides, it never deletes: the screens filter what they draw, nothing stored is removed.
// The list is kept in Haven's outbox (the user's own events live there), so it holds offline. Read-only: nothing
// here signs or publishes.
//
// Public entries are the `p` tags. A private part, when there is one, is the content: a JSON array of tags encrypted
// to the user's own key (NIP-44, or NIP-04 from older clients). Only a signer that can decrypt reads it; when this
// one can't, `privateNote` says why and only the public part applies.
import { pool, uniq } from "./pool.js"
import { findExtension } from "../signer/nip07.js"
import { groupNotifications, classify } from "./notifications.js"

const HEX64 = /^[0-9a-f]{64}$/
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

/** Hex pubkeys from a list of tags: valid `p` tags only, lowercased, once each. */
export function pTags(tags) {
  return uniq((Array.isArray(tags) ? tags : []).filter(t => Array.isArray(t) && t[0] === "p" && HEX64.test(String(t[1] ?? "").toLowerCase())).map(t => t[1].toLowerCase()))
}

/** NIP-04 ciphertext carries "?iv="; anything else is taken as NIP-44. */
export const isNip04 = s => /\?iv=/.test(s)

/**
 * How this session can open the private part. -> { decrypt: (ciphertext) => Promise<string> } or { reason }.
 * A NIP-07 extension can, if it offers the matching scheme. The bunker sign-in here only signs (src/signer/nip46.js
 * exposes no decrypt), so its private blocks stay closed. `ext` is for tests.
 */
export async function decrypterFor(session, { ext } = {}) {
  if (session?.method === "nip46") return { reason: "your bunker sign-in can't decrypt here yet" }
  if (session?.method !== "nip07") return { reason: "this sign-in can't decrypt" }
  const nostr = ext ?? (await findExtension())
  if (!nostr) return { reason: "your Nostr extension isn't there" }
  return {
    decrypt: async c => {
      const scheme = isNip04(c) ? "nip04" : "nip44"
      if (typeof nostr[scheme]?.decrypt !== "function") throw new Error(`your extension doesn't offer ${scheme.toUpperCase()} decryption`)
      return nostr[scheme].decrypt(session.pubkey, c)
    },
  }
}

/** The private entries of a kind 10000. -> { pubkeys, note } where note is "" when nothing was left unread. */
export async function privateBlocks(ev, opener) {
  const c = typeof ev?.content === "string" ? ev.content.trim() : ""
  if (!c) return { pubkeys: [], note: "" }
  if (!opener?.decrypt) return { pubkeys: [], note: opener?.reason ?? "no way to decrypt" }
  try {
    return { pubkeys: pTags(JSON.parse(await opener.decrypt(c))), note: "" }
  } catch (e) {
    return { pubkeys: [], note: e?.message ? String(e.message) : "couldn't decrypt it" }
  }
}

/** The newest kind 10000 Haven's outbox holds for the user. Works offline. */
export async function readBlockList(vault, pubkey) {
  return newest(await vault.outbox.query({ kinds: [10000], authors: [pubkey] }))
}

/** Fetch the newest kind 10000 from the network into Haven's outbox, then read it back. `query` is for tests. */
export async function refreshBlockList(vault, pubkey, relays, { query = (r, f, o) => pool.querySync(r, f, o), log = () => {} } = {}) {
  const ev = newest((await query(uniq(relays), { kinds: [10000], authors: [pubkey] }, { maxWait: 6000 })).filter(e => e?.kind === 10000 && e.pubkey === pubkey))
  if (ev) {
    const r = await vault.outbox.event(ev)
    if (!r.ok && !/^duplicate:/.test(r.message)) log("blocks-store-refused", { message: r.message })
  }
  return readBlockList(vault, pubkey)
}

// What the screens read. One list per signed-in account; a new account starts empty.
let state = { pubkey: null, blocked: new Set(), privateNote: "", eventId: null }
let loading = null
const listeners = new Set()

export const getBlocks = () => state
export function onBlocks(cb) { listeners.add(cb); return () => listeners.delete(cb) }

async function apply(pubkey, ev, opener) {
  if (!ev || ev.id === state.eventId) return
  const priv = await privateBlocks(ev, opener)
  if (state.pubkey !== pubkey) return // signed out or switched while decrypting
  state = { pubkey, blocked: new Set([...pTags(ev.tags), ...priv.pubkeys]), privateNote: priv.note, eventId: ev.id }
  for (const cb of listeners) cb()
}

/**
 * Load the block list once per account: Haven's copy first (so offline works), then the network's if it is newer.
 * Later calls for the same account return the same promise. `opener` and `query` are for tests.
 */
export function loadBlocks({ vault, session }, relays, { opener, query, log } = {}) {
  const pubkey = session.pubkey
  if (state.pubkey === pubkey && loading) return loading
  state = { pubkey, blocked: new Set(), privateNote: "", eventId: null }
  for (const cb of listeners) cb()
  loading = (async () => {
    const open = opener ?? (await decrypterFor(session))
    await apply(pubkey, await readBlockList(vault, pubkey), open)
    if (globalThis.navigator?.onLine === false) return
    await apply(pubkey, await refreshBlockList(vault, pubkey, relays, { query, log }), open)
  })().catch(e => log?.("blocks-load-failed", { message: String(e?.message ?? e) }))
  return loading
}

/** The author a kind 6 carries, from its embedded note, or null. */
function repostedAuthor(ev) {
  try { const inner = JSON.parse(ev.content); return typeof inner?.pubkey === "string" ? inner.pubkey.toLowerCase() : null } catch { return null }
}

/** True when a note is a blocked person's, or a repost of one (someone you follow can repost a blocked person). */
export function isBlockedNote(ev, blocked) {
  if (!ev || !blocked.size) return false
  if (blocked.has(String(ev.pubkey).toLowerCase())) return true
  return ev.kind === 6 && blocked.has(repostedAuthor(ev))
}

/** Notes left once blocked people's are taken out. */
export const visibleNotes = (evs, blocked) => (blocked.size ? evs.filter(ev => !isBlockedNote(ev, blocked)) : evs)

/** Pubkeys left once blocked people are taken out (Search's People). */
export const visiblePeople = (pubkeys, blocked) => (blocked.size ? pubkeys.filter(pk => !blocked.has(pk.toLowerCase())) : pubkeys)

/**
 * Notification rows without blocked people: their events are dropped and the rest grouped again, so a row three
 * people liked shows two once one is blocked, and a row only blocked people made is gone.
 */
export function visibleRows(rows, blocked, pubkey) {
  if (!blocked.size) return rows
  const evs = rows.flatMap(r => r.events).filter(ev => { const n = classify(ev, pubkey); return n && !blocked.has(n.who) })
  return groupNotifications(evs, pubkey)
}

/** A thread's reply tree without blocked people's replies. Their replies' own replies stay, moved up to their place. */
export function visibleReplies(replies, blocked) {
  if (!blocked.size) return replies
  return replies.flatMap(n => {
    const children = visibleReplies(n.children, blocked)
    return isBlockedNote(n.event, blocked) ? children : [{ event: n.event, children }]
  })
}
