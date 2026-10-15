// People the user blocked: their kind 10000 mute list (NIP-51), the same list the iPhone app writes when you block
// someone there. A block hides, it never deletes: the screens filter what they draw, nothing stored is removed.
// The list is kept in Haven's outbox (the user's own events live there), so it holds offline. Blocking and
// unblocking (setBlock) publish a new list built on the newest one found, the way follows.js edits the follow list.
//
// Public entries are the `p` tags. A private part, when there is one, is the content: a JSON array of tags encrypted
// to the user's own key (NIP-44, or NIP-04 from older clients). Only a signer that can decrypt reads it; when this
// one can't, `privateNote` says why and only the public part applies.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, PROFILE_RELAYS, uniq } from "./pool.js"
import { askRelay, MAX_SKEW } from "./follows.js"
import { checkSigned } from "./sync.js"
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
 * The signer opens it: a bunker through its nip44_decrypt / nip04_decrypt (signer/nip46.js bunkerCrypto), an
 * extension if it offers the matching scheme. `ext` is for tests.
 */
export async function decrypterFor(session, { ext, signer } = {}) {
  if (session?.method !== "nip07" && session?.method !== "nip46") return { reason: "this sign-in can't decrypt" }
  if (!ext && signer?.crypto) {
    const c = signer.crypto
    return { decrypt: ct => (isNip04(ct) ? c.decrypt04(session.pubkey, ct) : c.decrypt(session.pubkey, ct)) }
  }
  if (session.method === "nip46") return { reason: "your bunker isn't connected" }
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
let state = { pubkey: null, blocked: new Set(), privateBlocked: new Set(), privateNote: "", eventId: null }
let loading = null
const listeners = new Set()

export const getBlocks = () => state
/** Forget the loaded list, so the next loadBlocks reads it again (tests; a new account resets on its own). */
export function resetBlocks() { state = { pubkey: null, blocked: new Set(), privateBlocked: new Set(), privateNote: "", eventId: null }; loading = null; for (const cb of listeners) cb() }
export function onBlocks(cb) { listeners.add(cb); return () => listeners.delete(cb) }

async function apply(pubkey, ev, opener) {
  if (!ev || ev.id === state.eventId) return
  const priv = await privateBlocks(ev, opener)
  if (state.pubkey !== pubkey) return // signed out or switched while decrypting
  state = { pubkey, blocked: new Set([...pTags(ev.tags), ...priv.pubkeys]), privateBlocked: new Set(priv.pubkeys), privateNote: priv.note, eventId: ev.id }
  for (const cb of listeners) cb()
}

/**
 * Load the block list once per account: Haven's copy first (so offline works), then the network's if it is newer.
 * Later calls for the same account return the same promise. `opener` and `query` are for tests.
 */
export function loadBlocks({ vault, session, signer }, relays, { opener, query, log } = {}) {
  const pubkey = session.pubkey
  if (state.pubkey === pubkey && loading) return loading
  state = { pubkey, blocked: new Set(), privateBlocked: new Set(), privateNote: "", eventId: null }
  for (const cb of listeners) cb()
  loading = (async () => {
    const open = opener ?? (await decrypterFor(session, { signer }))
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

// ---- Blocking and unblocking ----

const now = () => Math.floor(Date.now() / 1000)

/** The newest kind 10000 by `pubkey` (ties: the lower id), skipping lists dated MAX_SKEW or more ahead. */
export function newestBlockList(lists, pubkey, at = now()) {
  let best
  for (const ev of lists) {
    if (ev?.kind !== 10000 || ev.pubkey !== pubkey || ev.created_at >= at + MAX_SKEW) continue
    if (!best || ev.created_at > best.created_at || (ev.created_at === best.created_at && ev.id < best.id)) best = ev
  }
  return best
}

/**
 * The newest kind 10000 from Haven's outbox and the user's relays (purplepag.es is asked too but doesn't count).
 * `answered`: how many of the user's own relays sent their EOSE; `netFound`: one of them had a list. `ask` is for tests.
 * -> { base, asked, answered, netFound }
 */
export async function findLatestBlockList({ vault, pubkey, relays, ask = askRelay }) {
  const filter = { kinds: [10000], authors: [pubkey] }
  const own = uniq(relays)
  const asked = uniq([...own, ...PROFILE_RELAYS])
  const [local, replies] = await Promise.all([
    vault.outbox.query(filter).catch(() => []),
    Promise.all(asked.map(url => ask(url, filter).catch(() => ({ events: [], answered: false })))),
  ])
  const net = replies.flatMap(r => r.events).filter(ev => ev?.kind === 10000 && ev.pubkey === pubkey && verifiedCopy(ev))
  const answered = replies.filter((r, i) => r.answered && own.includes(asked[i])).length
  const netFound = replies.some((r, i) => own.includes(asked[i]) && r.events.some(ev => ev?.kind === 10000 && ev.pubkey === pubkey && verifiedCopy(ev)))
  return { base: newestBlockList([...local, ...net], pubkey), asked: own.length, answered, netFound }
}

/** verifyEvent on a fresh copy: it trusts a "verified" flag an event object carries (follows.js does the same). */
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => {
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}

/**
 * Why a new list may not be built, or "". A kind 10000 replaces the whole list, so one built on an old copy would
 * bring back people unblocked elsewhere and drop people blocked since. As follows.js: unless one of the user's own
 * relays had a list, more than half of them must have answered (then "no list anywhere" really means none yet, and
 * the first block may start one). And as follows.js's size rule: when the app already shows more than 10 public
 * blocks, a newest list holding fewer than half of them is a truncated or stale copy, not something to build on.
 * `base`: the list found; `known`: how many public blocks the app shows now.
 */
export function blockGuard({ asked, answered, netFound, base, known = 0 }) {
  if (!netFound && !(asked > 0 && answered * 2 > asked)) {
    if (!answered) return "None of your relays answered, so your newest block list isn't known and nothing was changed. Try again when they're reachable."
    return `Only ${answered} of your ${asked} relays answered and none had your block list, so your newest one isn't known and nothing was changed. Try again when most of them are reachable.`
  }
  const have = pTags(base?.tags).length
  if (known > 10 && have < known / 2)
    return `The newest block list your relays have holds ${have} people but you had ${known}. Building on it would unblock most of them, so nothing was changed.`
  return ""
}

/** The private part's tags. -> { tags } ("" content: []), or { reason } when the signer can't open it. */
async function openPrivate(ev, crypto, me) {
  const c = typeof ev?.content === "string" ? ev.content.trim() : ""
  if (!c) return { tags: [] }
  if (!crypto) return { reason: "your signer can't open the private part of your block list" }
  try {
    const tags = JSON.parse(isNip04(c) ? await crypto.decrypt04(me, c) : await crypto.decrypt(me, c))
    if (!Array.isArray(tags)) throw new Error("it isn't a list")
    return { tags }
  } catch (e) { return { reason: `the private part of your block list couldn't be opened (${e?.message ?? e})` } }
}

const withoutP = (tags, target) => tags.filter(t => !(Array.isArray(t) && t[0] === "p" && String(t[1] ?? "").toLowerCase() === target))

/**
 * The new list's tags and content for blocking (`block`) or unblocking `target`. Every other entry, public or
 * private (words, hashtags, threads, other people), is kept as it was. A public block goes in the tags, which every
 * app reads, the iPhone included; a private one goes in the content, NIP-44 encrypted to the user. Unblocking takes
 * the person out of both. When the private part can't be opened, a public change keeps it as it is, and a change
 * that needs it refuses (throws): a private block, or unblocking someone who isn't in the public part.
 * `crypto` is the signer's (signer.crypto). -> { tags, content }
 */
export async function editedBlockList(base, { target, block, isPrivate = false, crypto, me }) {
  const inPublic = (base?.tags ?? []).some(t => Array.isArray(t) && t[0] === "p" && String(t[1] ?? "").toLowerCase() === target)
  const tags = withoutP(base?.tags ?? [], target)
  let content = base?.content ?? ""
  const priv = await openPrivate(base, crypto, me)
  const inPrivate = !priv.reason && priv.tags.some(t => Array.isArray(t) && t[0] === "p" && String(t[1] ?? "").toLowerCase() === target)
  // Not public and the private part won't open: they can only be on the private part, and republishing it as it is
  // would leave them blocked while saying they aren't.
  if (!block && !inPublic && priv.reason) throw new Error(`Couldn't unblock: ${priv.reason}.`)
  if (block && isPrivate) {
    if (priv.reason) throw new Error(`Couldn't block privately: ${priv.reason}.`)
    content = await crypto.encrypt(me, JSON.stringify([...withoutP(priv.tags, target), ["p", target]]))
  } else if (inPrivate) {
    // Blocked publicly now, or unblocked: either way they come out of the private part.
    content = await crypto.encrypt(me, JSON.stringify(withoutP(priv.tags, target)))
  }
  if (block && !isPrivate) tags.push(["p", target])
  return { tags, content }
}

/**
 * Block or unblock `target`: find the newest list, edit it, guard it, sign it, send it to the write relays, keep it in
 * Haven's outbox, and show it at once. Throws (and publishes nothing) when the guard refuses or nothing took it.
 * ctx: { vault, signer, session, account }. `ask` and `publish` are for tests. -> { event, relays }
 */
export async function setBlock(ctx, target, { block = true, isPrivate = false, ask, publish = (urls, ev) => pool.publish(urls, ev) } = {}) {
  const me = ctx.session.pubkey
  target = String(target ?? "").toLowerCase()
  if (!HEX64.test(target)) throw new Error("That isn't a profile that can be blocked.")
  if (target === me) throw new Error("You can't block yourself.")
  const { read = [], write = [] } = ctx.account.relays
  const found = await findLatestBlockList({ vault: ctx.vault, pubkey: me, relays: uniq([...read, ...write]), ask })
  const known = state.pubkey === me ? state.blocked.size - state.privateBlocked.size : 0
  const refused = blockGuard({ ...found, known })
  if (refused) throw new Error(refused)
  const { tags, content } = await editedBlockList(found.base, { target, block, isPrivate, crypto: ctx.signer.crypto, me })
  const template = { kind: 10000, created_at: Math.max(now(), (found.base?.created_at ?? 0) + 1), tags, content }
  const event = checkSigned(await ctx.signer.signEvent(template), template, me)
  const { network, local } = publishRelays(write)
  const urls = [...network, ...local]
  const results = await Promise.allSettled(publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason), local: i >= network.length }))
  if (!relays.some(r => r.ok && !r.local)) throw new Error(`No relay took it (0 of ${network.length}), so nothing changed. Try again.`)
  const stored = await ctx.vault.outbox.event(event)
  if (!stored.ok && !/^duplicate:/.test(stored.message)) throw new Error(`Sent, but Haven refused the block list: ${stored.message}`)
  if (state.pubkey === me) await apply(me, event, ctx.signer.crypto ? { decrypt: c => (isNip04(c) ? ctx.signer.crypto.decrypt04(me, c) : ctx.signer.crypto.decrypt(me, c)) } : null)
  return { event, relays }
}
