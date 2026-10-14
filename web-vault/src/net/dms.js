// Messages: the user's direct messages, as the iPhone app sends and reads them (DMService / NIP17Service).
// Sent as NIP-17: an unsigned kind 14 rumor, sealed in a kind 13 the user signs, gift-wrapped in a kind 1059
// signed by a throwaway key, one wrap to the other person and one to the user (the self-copy the iPhone keeps too).
// Read: kind 1059 wraps addressed to the user, and legacy kind 4 from older clients. Wraps are kept in Haven's
// /chat route (the iPhone's inbox), so they are there offline; kind 4 is not, /chat refuses it.
// Decrypted text lives only in memory here: nothing decrypted is ever written to Haven, localStorage or the log.
// Only a NIP-07 extension can decrypt (NIP-44 / NIP-04); the bunker sign-in only signs, so Messages says so.
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

/** How this session reads and writes message text. -> extension crypto, or { reason } when it can't decrypt. */
export function cryptoFor(session, { ext } = {}) {
  if (session?.method === "nip46") return { reason: "your bunker sign-in only signs, it can't decrypt here yet" }
  if (session?.method !== "nip07") return { reason: "this sign-in can't decrypt" }
  return ext ?? extensionCrypto()
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
 * Open a wrap addressed to `me`. -> { id, from, peer, content, at, legacy: false } or null when it isn't a wrap for
 * this user or any layer fails: a bad seal signature, a rumor claiming another sender, a wrap that won't decrypt.
 */
export async function unwrap(wrap, crypto, me) {
  try {
    if (wrap?.kind !== 1059 || !HEX64.test(wrap.pubkey ?? "")) return null
    const seal = JSON.parse(await crypto.decrypt(wrap.pubkey, wrap.content))
    if (seal?.kind !== 13 || !verifyEvent(seal)) return null
    const rumor = JSON.parse(await crypto.decrypt(seal.pubkey, seal.content))
    if (rumor?.kind !== 14 || rumor.pubkey !== seal.pubkey || typeof rumor.content !== "string") return null
    const peer = rumor.pubkey === me ? pTag(rumor.tags, me) : rumor.pubkey
    if (!peer) return null
    return { id: wrap.id, from: rumor.pubkey, peer, content: rumor.content, at: Number(rumor.created_at) || 0, legacy: false }
  } catch { return null }
}

/** A legacy kind 4 to or from `me`. -> { id, from, peer, content, at, legacy: true } or null. */
export async function openLegacy(ev, crypto, me) {
  try {
    if (ev?.kind !== 4) return null
    const peer = ev.pubkey === me ? pTag(ev.tags, me) : ev.pubkey
    if (!peer || (ev.pubkey !== me && pTag(ev.tags) !== me)) return null
    return { id: ev.id, from: ev.pubkey, peer, content: await crypto.decrypt04(peer, ev.content), at: ev.created_at, legacy: true }
  } catch { return null }
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

// What the screens read: decrypted messages by id, for one account, in memory only.
let state = { pubkey: null, messages: new Map(), note: "", loaded: false }
const opened = new Set() // wrap ids already tried (opened or failed), so a refresh doesn't ask the extension again
const listeners = new Set()
export const getMessages = () => state
export function onMessages(cb) { listeners.add(cb); return () => listeners.delete(cb) }
const changed = () => { for (const cb of listeners) cb() }

export function resetMessages(pubkey) {
  state = { pubkey, messages: new Map(), note: "", loaded: false }
  opened.clear()
  changed()
}

async function take(evs, crypto, me) {
  let added = 0
  for (const ev of evs) {
    if (!ev?.id || opened.has(ev.id) || state.pubkey !== me) continue
    opened.add(ev.id)
    const m = ev.kind === 4 ? await openLegacy(ev, crypto, me) : await unwrap(ev, crypto, me)
    if (m && state.pubkey === me) { state.messages.set(m.id, m); added++ }
  }
  if (added) { state = { ...state }; changed() }
  return added
}

/**
 * Load the user's messages: Haven's /chat first (offline), then the relays, storing new wraps in /chat.
 * With a signer that can't decrypt, nothing is opened and `note` says why. `query`, `crypto`, `chat` are for tests.
 * -> { stored } wraps newly kept in Haven
 */
export async function loadMessages({ vault, session }, relays, { crypto, query = (r, f, o) => pool.querySync(r, f, o), chat } = {}) {
  const me = session.pubkey
  if (state.pubkey !== me) resetMessages(me)
  const c = crypto ?? cryptoFor(session)
  if (c.reason) { state = { ...state, note: c.reason, loaded: true }; changed(); return { stored: 0 } }
  const store = chat ?? chatStore(vault)
  await take(await store.query({ kinds: [1059], "#p": [me] }).catch(() => []), c, me)
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
    await take([...wraps, ...legacyTo, ...legacyFrom], c, me)
  }
  state = { ...state, loaded: true }; changed()
  return { stored }
}

/** How far back a live subscription looks: a wrap's created_at is up to two days in the past (NIP-59), so `since`
 *  must reach that far or a relay never pushes a wrap that was just sent. Already-opened ids are skipped. */
export const WATCH_SINCE = 2 * 86400 + 3600

/** Keep listening for new wraps while a screen is open. `subscribe` is for tests. -> close() */
export function watchMessages({ vault, session }, relays, { crypto, chat, subscribe = (r, f, o) => pool.subscribe(r, f, o) } = {}) {
  const me = session.pubkey
  const c = crypto ?? cryptoFor(session)
  if (c.reason || !relays.length) return () => {}
  const store = chat ?? chatStore(vault)
  const sub = subscribe(uniq(relays), { kinds: [1059, 4], "#p": [me], since: now() - WATCH_SINCE }, {
    onevent: async ev => { if (ev.kind === 1059) await store.event(ev).catch(() => {}); await take([ev], c, me) },
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
 * Send `text` to `peer` as NIP-17: their wrap to their DM relays, the self-copy to the user's own DM relays and
 * Haven's /chat. Shown at once in the thread. -> { relays: [{ url, ok, message }] }; throws when no relay took it.
 */
export async function sendMessage(ctx, peer, text, { crypto, query, chat, publish = (urls, ev) => pool.publish(urls, ev) } = {}) {
  const me = ctx.session.pubkey
  const c = crypto ?? cryptoFor(ctx.session)
  if (c.reason) throw new Error(`Can't send: ${c.reason}`)
  const env = { signer: ctx.signer, crypto: c, me }
  const rumor = rumorFor(me, peer, text)
  const lookup = uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS])
  const [theirs, mine] = await Promise.all([
    dmRelaysFor(peer, lookup, { query, fallback: ctx.account.relays.write }),
    dmRelaysFor(me, lookup, { query, fallback: ctx.account.relays.write }),
  ])
  const [toThem, toMe] = await Promise.all([wrapFor(rumor, env, peer), wrapFor(rumor, env, me)])
  const extra = extraRelays()
  const sends = [
    ...uniq([...theirs, ...extra]).map(url => [url, toThem]),
    ...uniq([...mine, ...extra]).map(url => [url, toMe]),
  ]
  const results = await Promise.allSettled(sends.map(([url, ev]) => Promise.race([publish([url], ev)[0], timeout(8000)])))
  const relays = results.map((r, i) => ({ url: sends[i][0], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? String(r.value ?? "") : String(r.reason?.message ?? r.reason) }))
  if (!relays.some(r => r.ok)) throw new Error(`No relay took it (0 of ${relays.length})`)
  await (chat ?? chatStore(ctx.vault)).event(toMe).catch(() => {})
  opened.add(toMe.id); opened.add(toThem.id)
  if (state.pubkey === me) { state.messages.set(toMe.id, { id: toMe.id, from: me, peer, content: text, at: rumor.created_at, legacy: false }); state = { ...state }; changed() }
  return { relays }
}

const timeout = ms => new Promise((_, reject) => setTimeout(() => reject(new Error("relay didn't answer")), ms))

/** "#/dm/<hex>" -> hex, else null. */
export const peerOf = (hash = location.hash) => /^#\/?dm\/([0-9a-f]{64})$/.exec(hash)?.[1] ?? null
