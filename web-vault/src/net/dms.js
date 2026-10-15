// Messages: the user's direct messages, as the iPhone app sends and reads them (DMService / NIP17Service).
// Sent as NIP-17: an unsigned kind 14 rumor, sealed in a kind 13 the user signs, gift-wrapped in a kind 1059
// signed by a throwaway key, one wrap to the other person and one to the user (the self-copy the iPhone keeps too).
// Read: kind 1059 wraps addressed to the user, and legacy kind 4 from older clients. Wraps are kept in Haven's
// /chat route (the iPhone's inbox), so they are there offline; kind 4 is not, /chat refuses it.
// Decrypted text lives only in memory here: nothing decrypted is ever written to Haven, localStorage or the log.
// The text is encrypted and decrypted by the signer: a NIP-07 extension's nip44 / nip04, or a NIP-46 bunker's
// nip44_encrypt / nip44_decrypt / nip04_decrypt (signer/nip46.js bunkerCrypto). The user's key stays with the signer.
import { finalizeEvent, generateSecretKey, getEventHash, getPublicKey, verifyEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { makeAuthEvent } from "nostr-tools/nip42"
import { HavenClient } from "../../../web-relay/src/haven/client.js"
import { deviceKey } from "../haven/vault.js"
import { pool, DEFAULT_RELAYS, isLoopback, relayLists, uniq } from "./pool.js"
import { extensionCrypto } from "../signer/nip07.js"
import { checkSigned } from "./sync.js"

const HEX64 = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)
// NIP-59: a seal's and a wrap's created_at is set up to two days in the past, so timing says nothing.
const randomPast = () => now() - Math.floor(Math.random() * 2 * 86400)
const pTag = (tags, not) => (tags ?? []).find(t => t[0] === "p" && HEX64.test(t[1] ?? "") && t[1] !== not)?.[1] ?? null

/** How this session reads and writes message text: the signer's crypto (extension or bunker), or { reason } when
 *  there is none. `ext` is for tests. */
export function cryptoFor(session, { ext, signer } = {}) {
  if (session?.method !== "nip07" && session?.method !== "nip46") return { reason: "this sign-in can't decrypt" }
  if (ext) return ext
  if (signer?.crypto) return signer.crypto
  return session.method === "nip07" ? extensionCrypto() : { reason: "your bunker isn't connected" }
}

/** The kind 14 the other person reads: unsigned, its id computed like any event's. */
export function rumorFor(me, peer, content, created_at = now()) {
  const rumor = { kind: 14, pubkey: me, created_at, tags: [["p", peer]], content }
  return { ...rumor, id: getEventHash(rumor) }
}

/**
 * Seal `rumor` for `peer` (the seal is signed by the user through `signer`) and wrap it for `recipient` with a
 * throwaway key. `peer` is who the seal is encrypted to: the other person for their copy, the user for the self-copy.
 * -> the signed kind 1059
 */
export async function wrapFor(rumor, { signer, crypto, me }, peer, recipient = peer) {
  const sealTemplate = { kind: 13, created_at: randomPast(), tags: [], content: await crypto.encrypt(peer, JSON.stringify(rumor)) }
  const seal = checkSigned(await signer.signEvent(sealTemplate), sealTemplate, me)
  const sk = generateSecretKey()
  const key = nip44.getConversationKey(sk, recipient)
  return finalizeEvent({ kind: 1059, created_at: randomPast(), tags: [["p", recipient]], content: nip44.encrypt(JSON.stringify(seal), key) }, sk)
}

/**
 * One signer call. A failure is the signer's, not the message's: marked `refused` (or `unreachable`, from the bunker
 * signer) so `take` can tell it from a message that isn't the user's, and ask again later. A bunker that says "no
 * permission" and a ciphertext it can't open look the same from here; either way the message isn't open yet.
 */
async function signerCall(f) {
  try { return await f() } catch (e) {
    if (e?.unreachable || e?.refused) throw e
    throw Object.assign(new Error(String(e?.message ?? e)), { refused: true })
  }
}
const passOn = e => { if (e?.unreachable || e?.refused) throw e; return null }

/**
 * Open a wrap addressed to `me`. -> { id, from, peer, content, at, legacy: false }, or null when it isn't a message
 * for this user: a bad seal signature, a rumor claiming another sender, one that doesn't name the user, a layer that
 * isn't JSON. Throws (`refused` / `unreachable`) when the signer didn't decrypt it.
 */
export async function unwrap(wrap, crypto, me) {
  try {
    if (wrap?.kind !== 1059 || !HEX64.test(wrap.pubkey ?? "")) return null
    const seal = JSON.parse(await signerCall(() => crypto.decrypt(wrap.pubkey, wrap.content)))
    if (seal?.kind !== 13 || !verifyEvent(seal)) return null
    const rumor = JSON.parse(await signerCall(() => crypto.decrypt(seal.pubkey, seal.content)))
    if (rumor?.kind !== 14 || rumor.pubkey !== seal.pubkey || typeof rumor.content !== "string") return null
    const names = (rumor.tags ?? []).some(t => t[0] === "p" && t[1] === me)
    // Mine: the other person is the p tag, or me for a note to self. Theirs: a rumor that doesn't name me isn't mine.
    const peer = rumor.pubkey === me ? (pTag(rumor.tags, me) ?? (names ? me : null)) : names ? rumor.pubkey : null
    if (!peer) return null
    return { id: wrap.id, from: rumor.pubkey, peer, content: rumor.content, at: Number(rumor.created_at) || 0, legacy: false }
  } catch (e) { return passOn(e) }
}

/** A legacy kind 4 to or from `me`. -> { id, from, peer, content, at, legacy: true }, null when it isn't the user's,
 *  and throws as unwrap does when the signer didn't decrypt it. */
export async function openLegacy(ev, crypto, me) {
  try {
    if (ev?.kind !== 4) return null
    const peer = ev.pubkey === me ? pTag(ev.tags, me) : ev.pubkey
    if (!peer || (ev.pubkey !== me && pTag(ev.tags) !== me)) return null
    return { id: ev.id, from: ev.pubkey, peer, content: await signerCall(() => crypto.decrypt04(peer, ev.content)), at: ev.created_at, legacy: true }
  } catch (e) { return passOn(e) }
}

/** Relays a person's DMs go to, as the iPhone picks them: their kind 10050, else their kind 10002 read list,
 *  else `fallback`. Loopback addresses are dropped: someone else's 127.0.0.1 is this machine. `query` is for tests. */
export async function dmRelaysFor(pubkey, lookupRelays, { fallback = DEFAULT_RELAYS, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq(lookupRelays), { kinds: [10050, 10002], authors: [pubkey] }, { maxWait: 6000 })
  const newest = k => evs.filter(e => e.kind === k && e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)[0]
  const inbox = (newest(10050)?.tags ?? []).filter(t => t[0] === "relay" && /^wss?:\/\//.test(t[1] ?? "")).map(t => t[1].replace(/\/+$/, ""))
  const usable = list => uniq(list.filter(u => !isLoopback(u)))
  if (usable(inbox).length) return usable(inbox)
  const general = newest(10002)
  if (general && usable(relayLists(general).read).length) return usable(relayLists(general).read)
  return uniq(fallback)
}

/** Extra DM relays for this browser (e.g. a relay on this machine), from localStorage "nv-dm-relays", comma separated. */
export function extraRelays(storage = globalThis.localStorage) {
  return (storage?.getItem("nv-dm-relays") ?? "").split(",").map(s => s.trim()).filter(u => /^wss?:\/\//.test(u))
}

// Haven's /chat route, opened once per vault like vault.js opens /feed: the iPhone keeps its wraps there.
const RELAY_HOST = "vault.local"
const chats = new WeakMap()
export function chatStore(vault) {
  if (vault.chat) return vault.chat
  if (!chats.has(vault)) {
    const conn = vault.haven.conn("ui-chat", { mode: "nip01", route: "/chat", owner: true })
    chats.set(vault, new HavenClient(conn, { auth: challenge => finalizeEvent(makeAuthEvent(`wss://${RELAY_HOST}/chat`, challenge), deviceKey()) }))
  }
  return chats.get(vault)
}

// What the screens read: decrypted messages by id, for one account, in memory only. `more`: messages waiting to be
// opened (past the first load's ceiling, or past the live rate), which "Open more" opens.
let state = { pubkey: null, messages: new Map(), note: "", trouble: "", more: 0, loaded: false }
const opened = new Set() // wrap ids opened, or found not to be the user's, so a refresh doesn't ask the signer again
const waiting = new Map() // id -> event, not asked yet
const listeners = new Set()
export const getMessages = () => state
export function onMessages(cb) { listeners.add(cb); return () => listeners.delete(cb) }
const changed = () => { for (const cb of listeners) cb() }

export function resetMessages(pubkey) {
  state = { pubkey, messages: new Map(), note: "", trouble: "", more: 0, loaded: false }
  opened.clear()
  waiting.clear()
  refusals.clear()
  changed()
}

/** Wraps opened per round: each costs two signer calls, so a first load of hundreds shows the newest ones first. */
export const OPEN_BATCH = 8
/** How many messages one load (or one "Open more") asks the signer to open, newest first. Each is two requests, and
 *  through a bunker each request is a relay round trip and maybe a prompt, so a bunker gets a lower ceiling. */
export const OPEN_LIMIT = { nip46: 40, other: 200 }
export const openLimit = session => (session?.method === "nip46" ? OPEN_LIMIT.nip46 : OPEN_LIMIT.other)

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`
const setMore = () => { state = { ...state, more: waiting.size } }

/** A message the signer refused this many times is settled like one that isn't the user's (a junk wrap no one can
 *  open would otherwise be asked about first on every load, ahead of real messages). Try again resets the count. */
export const MAX_REFUSALS = 2
const refusals = new Map() // id -> times the signer refused it

// The banner's wording is ours alone: a signer's error text never reaches the screen (a hostile bunker could write
// "re-authorise at https://…" into it).
export const TROUBLE_REFUSED = n => `Your signer didn't open ${plural(n, "message")}.`
export const TROUBLE_UNREACHABLE = "Your signer didn't answer, or its relay couldn't be reached."

/**
 * Open `evs` a batch at a time, telling the screens after each batch, at most `limit` of them: never-asked ones first,
 * newest first, then ones the signer refused before. The rest wait for "Open more". -> { added, asked } (`asked`: how
 * many the signer was actually asked about)
 * - not the user's (null): stays in `opened`, never asked again;
 * - the signer refused: freed to be asked again, until MAX_REFUSALS, then settled; `trouble` says how many;
 * - the signer stopped answering (a bunker that's offline: each request would wait out its timeout): the run stops,
 *   `trouble` says so, and what wasn't asked is asked next time.
 */
async function take(evs, crypto, me, { limit = Infinity } = {}) {
  let added = 0, refused = 0, asked = 0
  const fresh = []
  for (const ev of evs) {
    if (!ev?.id || opened.has(ev.id) || state.pubkey !== me) continue
    if (!fresh.some(f => f.id === ev.id)) fresh.push(ev)
  }
  const tried = ev => (refusals.get(ev.id) ?? 0) > 0
  fresh.sort((a, b) => tried(a) - tried(b) || (b.created_at ?? 0) - (a.created_at ?? 0))
  const now = fresh.slice(0, limit)
  const moreBefore = state.more
  for (const ev of fresh.slice(limit)) waiting.set(ev.id, ev)
  for (const ev of now) { waiting.delete(ev.id); opened.add(ev.id) }
  setMore()
  for (let i = 0; i < now.length && state.pubkey === me; i += OPEN_BATCH) {
    const batch = now.slice(i, i + OPEN_BATCH)
    asked += batch.length
    const got = await Promise.all(batch.map(ev => (ev.kind === 4 ? openLegacy(ev, crypto, me) : unwrap(ev, crypto, me)).catch(e => ({ failed: e }))))
    if (state.pubkey !== me) return { added, asked }
    let n = 0, lost = false
    got.forEach((m, j) => {
      const id = batch[j].id
      if (m?.id) { state.messages.set(m.id, m); refusals.delete(id); n++; return }
      if (!m?.failed) return // not the user's: stays in `opened`
      if (m.failed.unreachable) { opened.delete(id); lost = true; return }
      refused++
      const times = (refusals.get(id) ?? 0) + 1
      refusals.set(id, times)
      if (times < MAX_REFUSALS) opened.delete(id) // asked again later; at MAX_REFUSALS it stays settled
    })
    added += n
    if (lost) {
      for (const ev of now.slice(i + OPEN_BATCH)) opened.delete(ev.id)
      state = { ...state, trouble: TROUBLE_UNREACHABLE }
      setMore(); changed()
      return { added, asked }
    }
    if (n) { state = { ...state }; changed() }
  }
  if (refused) state = { ...state, trouble: TROUBLE_REFUSED(refused) }
  setMore()
  if (refused || state.more !== moreBefore) changed()
  return { added, asked }
}

/** Try again: everything not open is asked again, the ones the signer refused (even twice) included. */
export function forgetUnopened() {
  for (const id of opened) if (!state.messages.has(id)) opened.delete(id)
  refusals.clear()
  if (state.trouble) { state = { ...state, trouble: "" }; changed() }
}

// Loading and "Open more" run one at a time, so the same message is never asked about twice at once.
let running = Promise.resolve()
const oneAtATime = f => { const r = running.then(f, f); running = r.catch(() => {}); return r }

/** "Open more": the next `limit` waiting messages, newest first. */
export function openMore({ session, signer }, { crypto } = {}) {
  return oneAtATime(async () => {
    const c = crypto ?? cryptoFor(session, { signer })
    if (c.reason || !waiting.size || state.pubkey !== session.pubkey) return { added: 0, asked: 0 }
    return take([...waiting.values()], c, session.pubkey, { limit: openLimit(session) })
  })
}

/**
 * Load the user's messages: Haven's /chat first (offline), then the relays, storing new wraps in /chat.
 * With a signer that can't decrypt, nothing is opened and `note` says why. `query`, `crypto`, `chat` are for tests.
 * -> { stored } wraps newly kept in Haven
 */
export function loadMessages(ctx, relays, opts = {}) {
  return oneAtATime(() => load(ctx, relays, opts))
}

async function load({ vault, session, signer }, relays, { crypto, query = (r, f, o) => pool.querySync(r, f, o), chat } = {}) {
  const me = session.pubkey
  if (state.pubkey !== me) resetMessages(me)
  if (state.trouble) { state = { ...state, trouble: "" }; changed() }
  const c = crypto ?? cryptoFor(session, { signer })
  if (c.reason) { state = { ...state, note: c.reason, loaded: true }; changed(); return { stored: 0 } }
  const store = chat ?? chatStore(vault)
  let budget = openLimit(session)
  budget -= (await take(await store.query({ kinds: [1059], "#p": [me] }).catch(() => []), c, me, { limit: budget })).asked
  let stored = 0
  if (globalThis.navigator?.onLine !== false && relays.length) {
    const urls = uniq(relays)
    // One filter per query: pool.querySync wraps its filter in an array itself, so a list here would reach the relay
    // as ["REQ", id, [f1, f2]], which every relay refuses.
    const [wraps, legacyTo, legacyFrom] = await Promise.all([
      query(urls, { kinds: [1059], "#p": [me], limit: 500 }, { maxWait: 8000 }),
      query(urls, { kinds: [4], "#p": [me], limit: 200 }, { maxWait: 8000 }),
      query(urls, { kinds: [4], authors: [me], limit: 200 }, { maxWait: 8000 }),
    ])
    for (const w of wraps) if (!opened.has(w.id) && (await store.event(w).catch(() => ({ ok: false }))).ok) stored++
    await take([...wraps, ...legacyTo, ...legacyFrom], c, me, { limit: Math.max(0, budget) })
  }
  state = { ...state, loaded: true }; changed()
  return { stored }
}

/** How far back a live subscription looks: a wrap's created_at is up to two days in the past (NIP-59), so `since`
 *  must reach that far or a relay never pushes a wrap that was just sent. Already-opened ids are skipped. */
export const WATCH_SINCE = 2 * 86400 + 3600

/** How many live messages a minute are opened as they arrive; past that they wait for "Open more". Anyone can send
 *  a wrap, and through a bunker each one is requests (maybe prompts) on the user's signer. */
export const LIVE_PER_MINUTE = { nip46: 6, other: 30 }

/** Keep listening for new wraps while a screen is open. `subscribe` and `clock` are for tests. -> close() */
export function watchMessages({ vault, session, signer }, relays, { crypto, chat, subscribe = (r, f, o) => pool.subscribe(r, f, o), clock = () => Date.now() } = {}) {
  const me = session.pubkey
  const c = crypto ?? cryptoFor(session, { signer })
  if (c.reason || !relays.length) return () => {}
  const store = chat ?? chatStore(vault)
  const perMinute = session.method === "nip46" ? LIVE_PER_MINUTE.nip46 : LIVE_PER_MINUTE.other
  let recent = [] // when live messages were opened, within the last minute
  const sub = subscribe(uniq(relays), { kinds: [1059, 4], "#p": [me], since: now() - WATCH_SINCE }, {
    onevent: async ev => {
      if (ev.kind === 1059) await store.event(ev).catch(() => {})
      if (!ev?.id || opened.has(ev.id) || state.pubkey !== me) return
      const t = clock()
      recent = recent.filter(at => t - at < 60_000)
      if (recent.length >= perMinute) { waiting.set(ev.id, ev); setMore(); changed(); return }
      recent.push(t)
      await take([ev], c, me)
    },
  })
  return () => sub.close()
}

/** Conversations, newest first, blocked people left out. -> [{ peer, last, count }] */
export function conversations(messages, blocked = new Set()) {
  const byPeer = new Map()
  for (const m of messages.values()) {
    if (blocked.has(m.peer)) continue
    const c = byPeer.get(m.peer)
    if (!c) byPeer.set(m.peer, { peer: m.peer, last: m, count: 1 })
    else { c.count++; if (m.at > c.last.at) c.last = m }
  }
  return [...byPeer.values()].sort((a, b) => b.last.at - a.last.at)
}

/** One conversation, oldest first. */
export const thread = (messages, peer) => [...messages.values()].filter(m => m.peer === peer).sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1))

/**
 * Send `text` to `peer` as NIP-17: their wrap to their DM relays, the self-copy to the user's own DM relays (plus
 * this browser's extra relays) and Haven's /chat. Shown at once in the thread. A note to self is one wrap to my
 * relays. -> { relays: [{ url, ok, message, to: "them" | "me" }] }; throws when none of the recipient's relays
 * took their wrap (the self-copy landing somewhere is not delivery).
 */
// What a failed send says. Our sentences only: a signer's or a relay's own error text never reaches the screen (a
// hostile bunker could write "re-authorise at https://…" into it). An error carrying `fixed` is safe to show.
export const SEND_FAILED = {
  signer: "Your signer didn't seal the message, so it wasn't sent.",
  unreachable: "Your signer didn't answer, or its relay couldn't be reached, so the message wasn't sent.",
  other: "The message wasn't sent. Try again.",
}
const sendError = message => Object.assign(new Error(message), { fixed: true })
/** What the screen says when a send fails: sendMessage's own sentence, never anyone else's error text. */
export const sendFailure = err => (err?.fixed ? String(err.message) : SEND_FAILED.other)

export async function sendMessage(ctx, peer, text, { crypto, query, chat, publish = (urls, ev) => pool.publish(urls, ev) } = {}) {
  const me = ctx.session.pubkey
  const c = crypto ?? cryptoFor(ctx.session, { signer: ctx.signer })
  if (c.reason) throw sendError(`Can't send: ${c.reason}`)
  const env = { signer: ctx.signer, crypto: c, me }
  const rumor = rumorFor(me, peer, text)
  const lookup = uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS])
  const [theirs, mine] = await Promise.all([
    dmRelaysFor(peer, lookup, { query, fallback: ctx.account.relays.write }),
    dmRelaysFor(me, lookup, { query, fallback: ctx.account.relays.write }),
  ]).catch(() => { throw sendError(SEND_FAILED.other) })
  const self = peer === me
  let toMe, toThem
  try {
    toMe = await wrapFor(rumor, env, me)
    toThem = self ? toMe : await wrapFor(rumor, env, peer)
  } catch (e) { throw sendError(e?.unreachable ? SEND_FAILED.unreachable : SEND_FAILED.signer) }
  const send = async (urls, ev, to) => {
    const results = await Promise.allSettled(urls.map(url => Promise.race([publish([url], ev)[0], timeout(8000)])))
    return results.map((r, i) => ({ url: urls[i], to, ok: r.status === "fulfilled", message: r.status === "fulfilled" ? String(r.value ?? "") : String(r.reason?.message ?? r.reason) }))
  }
  // Their wrap first: the self-copy goes out only once a recipient relay took theirs, so a refused message never
  // comes back from my own relay looking sent.
  const mineUrls = uniq([...mine, ...extraRelays()])
  const theirSends = await send(self ? mineUrls : uniq(theirs), toThem, "them")
  if (!theirSends.some(r => r.ok)) throw sendError(`Not delivered: none of their ${theirSends.length} relay${theirSends.length === 1 ? "" : "s"} took it.`)
  const relays = [...theirSends, ...(self ? [] : await send(mineUrls, toMe, "me"))]
  await (chat ?? chatStore(ctx.vault)).event(toMe).catch(() => {})
  opened.add(toMe.id); opened.add(toThem.id)
  if (state.pubkey === me) { state.messages.set(toMe.id, { id: toMe.id, from: me, peer, content: text, at: rumor.created_at, legacy: false }); state = { ...state }; changed() }
  return { relays }
}

const timeout = ms => new Promise((_, reject) => setTimeout(() => reject(new Error("relay didn't answer")), ms))

/** "#/dm/<hex>" -> hex, else null. */
export const peerOf = (hash = location.hash) => /^#\/?dm\/([0-9a-f]{64})$/.exec(hash)?.[1] ?? null
