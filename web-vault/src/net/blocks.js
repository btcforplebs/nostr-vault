// People the user blocked: their kind 10000 mute list (NIP-51), the same list the iPhone app writes when you block
// someone there. A block hides, it never deletes: the screens filter what they draw, nothing stored is removed.
// The list is kept in Haven's outbox (the user's own events live there), so it holds offline. Blocking and
// unblocking (setBlock) publish a new list built on the newest one found, the way follows.js edits the follow list.
//
// Public entries are the tags. A private part, when there is one, is the content: a JSON array of tags encrypted
// to the user's own key (NIP-44, or NIP-04 from older clients). Only a signer that can decrypt reads it; when this
// one can't, `privateNote` says why and only the public part applies. People are the `p` entries; muted words
// (`word`), hashtags (`t`) and threads (`e`) ride on the same Set as `words`, `hashtags` and `threads` (muteSet), so
// every screen that already hides blocked people's notes hides muted ones too.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, relayLists, BROADCAST_RELAYS, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { askRelay, MAX_SKEW } from "./follows.js"
import { checkSigned } from "./sync.js"
import { replyRefs, repostInner } from "./thread.js"
import { findExtension } from "../signer/nip07.js"
import { groupNotifications, classify } from "./notifications.js"

const HEX64 = /^[0-9a-f]{64}$/
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

/** Hex pubkeys from a list of tags: valid `p` tags only, lowercased, once each. */
export function pTags(tags) {
  return uniq((Array.isArray(tags) ? tags : []).filter(t => Array.isArray(t) && t[0] === "p" && HEX64.test(String(t[1] ?? "").toLowerCase())).map(t => t[1].toLowerCase()))
}

/** The list's muted words (lowercased), hashtags (lowercased, no #) and threads (event ids), from a list of tags. */
export function muteEntries(tags) {
  const ts = (Array.isArray(tags) ? tags : []).filter(t => Array.isArray(t) && typeof t[1] === "string" && t[1].trim())
  const of = name => uniq(ts.filter(t => t[0] === name).map(t => t[1].trim().toLowerCase()))
  return {
    words: of("word"),
    hashtags: new Set(of("t").map(t => t.replace(/^#/, ""))),
    threads: new Set(of("e").filter(id => HEX64.test(id))),
  }
}

/** A Set of blocked pubkeys carrying the muted words, hashtags and threads (muteEntries) along with it. */
export function muteSet(pubkeys = [], tags = []) {
  return Object.assign(new Set(pubkeys), muteEntries(tags))
}

/** True when `blocked` hides anything: people, or muted words, hashtags or threads. */
export const blocksAny = blocked => !!blocked && (blocked.size > 0 || blocked.words?.length > 0 || blocked.hashtags?.size > 0 || blocked.threads?.size > 0)

/** True when a note's own words, hashtags or thread are muted. A plain Set (no mutes) never mutes. */
export function isMutedNote(ev, blocked) {
  if (!ev || !blocked) return false
  const { words, hashtags, threads } = blocked
  if (threads?.size) {
    if (threads.has(ev.id)) return true
    const { root, parent } = replyRefs(ev)
    if ((root && threads.has(root)) || (parent && threads.has(parent))) return true
  }
  if (hashtags?.size && (ev.tags ?? []).some(t => t[0] === "t" && hashtags.has(String(t[1] ?? "").toLowerCase().replace(/^#/, "")))) return true
  if (words?.length) {
    const text = String(ev.content ?? "").toLowerCase()
    if (text && words.some(w => text.includes(w))) return true
  }
  return false
}

/** NIP-04 ciphertext carries "?iv="; anything else is taken as NIP-44. */
export const isNip04 = s => /\?iv=/.test(s)

/**
 * How this session can open the private part. -> { decrypt: (ciphertext) => Promise<string> } or { reason }.
 * The signer opens it: a bunker through its nip44_decrypt / nip04_decrypt (signer/nip46.js bunkerCrypto), an
 * extension if it offers the matching scheme. `ext` is for tests.
 */
export async function decrypterFor(session, { ext, signer } = {}) {
  if (session?.method !== "nip07" && session?.method !== "nip46" && session?.method !== "local") return { reason: "this sign-in can't decrypt" }
  if (!ext && signer?.crypto) {
    const c = signer.crypto
    return { decrypt: ct => (isNip04(ct) ? c.decrypt04(session.pubkey, ct) : c.decrypt(session.pubkey, ct)) }
  }
  if (session.method === "nip46") return { reason: "your bunker isn't connected" }
  if (session.method === "local") return { reason: "your key isn't unlocked" }
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

/** The private entries of a kind 10000. -> { pubkeys, tags, note } where note is "" when nothing was left unread. */
export async function privateBlocks(ev, opener) {
  const c = typeof ev?.content === "string" ? ev.content.trim() : ""
  if (!c) return { pubkeys: [], tags: [], note: "" }
  if (!opener?.decrypt) return { pubkeys: [], tags: [], note: opener?.reason ?? "no way to decrypt" }
  try {
    const tags = JSON.parse(await opener.decrypt(c))
    if (!Array.isArray(tags)) throw new Error("it isn't a list")
    return { pubkeys: pTags(tags), tags, note: "" }
  } catch (e) {
    return { pubkeys: [], tags: [], note: e?.message ? String(e.message) : "couldn't decrypt it" }
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
const empty = pubkey => ({ pubkey, blocked: muteSet(), privateBlocked: new Set(), privateNote: "", eventId: null })
let state = empty(null)
let loading = null
let asked = new Set() // relays already asked for this account's list
const listeners = new Set()

export const getBlocks = () => state
/** Forget the loaded list, so the next loadBlocks reads it again (tests; a new account resets on its own). */
export function resetBlocks() { state = empty(null); loading = null; asked = new Set(); for (const cb of listeners) cb() }
export function onBlocks(cb) { listeners.add(cb); return () => listeners.delete(cb) }

// The same list is read again only when its private part couldn't be opened last time (a bunker that hadn't
// connected yet, an extension that was locked): this try may open it.
async function apply(pubkey, ev, opener) {
  if (!ev || (ev.id === state.eventId && !state.privateNote)) return
  if (state.eventId && ev.id !== state.eventId && ev.created_at < (state.created_at ?? 0)) return // never go back to an older list
  const priv = await privateBlocks(ev, opener)
  if (state.pubkey !== pubkey) return // signed out or switched while decrypting
  state = { pubkey, blocked: muteSet([...pTags(ev.tags), ...priv.pubkeys], [...(ev.tags ?? []), ...priv.tags]), privateBlocked: new Set(priv.pubkeys), privateNote: priv.note, eventId: ev.id, created_at: ev.created_at }
  for (const cb of listeners) cb()
}

/**
 * Load the block list for an account: Haven's copy first (so offline works), then the network's if it is newer.
 * A later call for the same account asks only relays not asked yet (the account's own relays arrive after sign-in,
 * once its kind 10002 is read), and tries the private part again if it couldn't be opened. `opener` and `query`
 * are for tests.
 */
export function loadBlocks({ vault, session, signer }, relays, { opener, query, log } = {}) {
  const pubkey = session.pubkey
  const fresh = uniq(relays).filter(r => !asked.has(r))
  if (state.pubkey === pubkey && loading && !fresh.length) return loading
  if (state.pubkey !== pubkey) { state = empty(pubkey); asked = new Set(); loading = null; for (const cb of listeners) cb() }
  for (const r of fresh) asked.add(r)
  const before = loading ?? Promise.resolve() // one load at a time per account, so lists land in order
  loading = before.then(async () => {
    const open = opener ?? (await decrypterFor(session, { signer }))
    await apply(pubkey, await readBlockList(vault, pubkey), open)
    if (globalThis.navigator?.onLine === false || !fresh.length) return
    await apply(pubkey, await refreshBlockList(vault, pubkey, fresh, { query, log }), open)
  }).catch(e => log?.("blocks-load-failed", { message: String(e?.message ?? e) }))
  return loading
}

/** A repost or reaction whose `e` tag points at a muted thread. */
const isMutedThreadRef = (ev, blocked) => !!blocked?.threads?.size && (ev.tags ?? []).some(t => t[0] === "e" && blocked.threads.has(String(t[1] ?? "").toLowerCase()))

/** True when a note is a blocked person's, a repost of one (someone you follow can repost a blocked person), or a reply
 *  to one, when `authorOf` knows who wrote the parent (the iPhone's FeedFilterEngine.isBlocked). A repost whose note
 *  doesn't check is hidden if its p tag names a blocked person, but a p tag never clears one: the card checks the note
 *  it fetches by id instead (repostState). */
export function isBlockedNote(ev, blocked, authorOf = () => null) {
  if (!ev || !blocksAny(blocked)) return false
  if (blocked.has(String(ev.pubkey).toLowerCase())) return true
  if (ev.kind === 6 || ev.kind === 16) {
    const inner = repostInner(ev)
    if (inner) return blocked.has(inner.pubkey.toLowerCase()) || isMutedNote(inner, blocked) || isMutedThreadRef(ev, blocked)
    return blocked.has((ev.tags ?? []).find(t => t[0] === "p")?.[1]?.toLowerCase()) || isMutedThreadRef(ev, blocked)
  }
  if (isMutedNote(ev, blocked)) return true
  if (ev.kind === 1111) {
    const answered = (ev.tags ?? []).find(t => t[0] === "p")?.[1]?.toLowerCase()
    if (answered && blocked.has(answered)) return true
  }
  const parent = ev.kind === 1 ? replyRefs(ev).parent : null
  const parentAuthor = parent && authorOf(parent)
  return !!parentAuthor && blocked.has(String(parentAuthor).toLowerCase())
}

/** What a repost card shows for the note it fetched by id: "loading", "missing" (not found, or not a kind `kinds`
 *  allows), "blocked" (a blocked person's note, whoever the repost claimed it was), or "note". */
export function repostState(ev, kinds, blocked) {
  if (ev === undefined) return "loading"
  if (!kinds.has(ev?.kind)) return "missing"
  return blocksAny(blocked) && isBlockedNote(ev, blocked) ? "blocked" : "note"
}

/** Notes left once blocked people's, and replies to the blocked people's notes among them, are taken out. */
export function visibleNotes(evs, blocked) {
  if (!blocksAny(blocked)) return evs
  const byId = new Map(evs.map(ev => [ev.id, ev]))
  return evs.filter(ev => !isBlockedNote(ev, blocked, id => byId.get(id)?.pubkey))
}

/** Pubkeys left once blocked people are taken out (Search's People). */
export const visiblePeople = (pubkeys, blocked) => (blocked.size ? pubkeys.filter(pk => !blocked.has(pk.toLowerCase())) : pubkeys)

/**
 * Notification rows without blocked people: their events are dropped and the rest grouped again, so a row three
 * people liked shows two once one is blocked, and a row only blocked people made is gone.
 */
export function visibleRows(rows, blocked, pubkey) {
  if (!blocksAny(blocked)) return rows
  const evs = rows.flatMap(r => r.events).filter(ev => {
    const n = classify(ev, pubkey)
    if (!n || blocked.has(n.who)) return false
    if (n.noteId && blocked.threads?.has(n.noteId)) return false // a like or zap on a note in a muted thread
    return !((ev.kind === 1 || ev.kind === 1111) && isMutedNote(ev, blocked))
  })
  return groupNotifications(evs, pubkey)
}

/** A thread's reply tree without blocked people's replies. Their replies' own replies stay, moved up to their place. */
export function visibleReplies(replies, blocked) {
  if (!blocksAny(blocked)) return replies
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
 * The relays of the user's newest kind 10002 found on `relays`, the defaults and the index relays. The account's own
 * list may not be loaded yet (then it is the defaults), and a list another app wrote (Amethyst) can be on the relays
 * that 10002 names alone. `known`: a 10002 was found, or every relay asked answered without one, so "no 10002" is
 * real and not a relay that timed out. -> { urls, known }
 */
async function listedRelays({ pubkey, relays, ask }) {
  const filter = { kinds: [10002], authors: [pubkey] }
  const replies = await Promise.all(uniq([...relays, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]).map(url => ask(url, filter).catch(() => ({ events: [], answered: false }))))
  const ev = replies.flatMap(r => r.events).filter(e => e?.kind === 10002 && e.pubkey === pubkey && verifiedCopy(e)).reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)
  if (!ev) return { urls: [], known: replies.every(r => r.answered) }
  const { read, write } = relayLists(ev)
  return { urls: uniq([...read, ...write]), known: true }
}

/**
 * The newest kind 10000 from Haven's outbox and the network. The user's own relays are `relays` plus those its newest
 * kind 10002 names (listedRelays); purplepag.es and the broadcast relays a new list is also sent to are asked too but
 * don't count unless that 10002 names them. `answered`: how many of the user's own relays sent their EOSE; `netFound`: one of them had a list;
 * `relaysKnown`: whether the 10002 is known (listedRelays), so the user's own relays are all of them.
 * `ask` is for tests. -> { base, asked, answered, netFound, relaysKnown }
 */
export async function findLatestBlockList({ vault, pubkey, relays, ask = askRelay }) {
  const filter = { kinds: [10000], authors: [pubkey] }
  const askAll = urls => Promise.all(urls.map(url => ask(url, filter).catch(() => ({ events: [], answered: false }))))
  const first = uniq([...relays, ...PROFILE_RELAYS, ...BROADCAST_RELAYS])
  const [local, firstReplies, listed] = await Promise.all([
    vault.outbox.query(filter).catch(() => []),
    askAll(first),
    listedRelays({ pubkey, relays, ask }),
  ])
  const more = listed.urls.filter(u => !first.includes(u))
  const urls = [...first, ...more]
  const replies = [...firstReplies, ...(await askAll(more))]
  const own = uniq([...relays, ...listed.urls]) // a 10002 relay counts even when it was in `first` already
  const mine = i => own.includes(urls[i])
  const lists = r => r.events.filter(ev => ev?.kind === 10000 && ev.pubkey === pubkey && verifiedCopy(ev))
  const answered = replies.filter((r, i) => r.answered && mine(i)).length
  const netFound = replies.some((r, i) => mine(i) && lists(r).length > 0)
  return { base: newestBlockList([...local, ...replies.flatMap(lists)], pubkey), asked: own.length, answered, netFound, relaysKnown: listed.known }
}

/** verifyEvent on a fresh copy: it trusts a "verified" flag an event object carries (follows.js does the same). */
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => {
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}

/**
 * Why a new list may not be built, or "". A kind 10000 replaces the whole list, so one built on an old copy, or on
 * none, would drop what other apps added (Amethyst's blocks, words, hashtags, threads, the private part) and bring
 * back people unblocked elsewhere. So a new list is built on the newest one the user's relays had; when none of them
 * had one, every one of them must have answered, so "no list anywhere" really means none yet and the first block may
 * start one. And as follows.js's size rule: when the app already shows more than 10 public blocks, a newest list
 * holding fewer than half of them is a truncated or stale copy, not something to build on. All of this needs the
 * user's relays: when their kind 10002 isn't known (`relaysKnown` false: none found and a relay asked for it didn't
 * answer), the relays it names weren't asked and may hold the newest list, so nothing is built.
 * `base`: the list found; `known`: how many public blocks the app shows now.
 */
export function blockGuard({ asked, answered, netFound, relaysKnown, base, known = 0 }) {
  if (!netFound && !(asked > 0 && answered === asked)) {
    if (!answered) return "None of your relays answered, so your newest block list isn't known and nothing was changed. Try again when they're reachable."
    return `Only ${answered} of your ${asked} relays answered and none had your block list, so your newest one isn't known and nothing was changed. Try again when they're all reachable.`
  }
  if (relaysKnown !== true) return "Your relay list (kind 10002) couldn't be loaded, so the relays that may hold your block list weren't asked and nothing was changed. Try again when they're reachable."
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
