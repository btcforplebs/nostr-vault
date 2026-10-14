// The user's Lightning wallet over Nostr Wallet Connect (NIP-47), as the iPhone app connects it (WalletSettingsView,
// NWCService): paste a nostr+walletconnect link; requests are kind 23194 events signed with the link's secret and
// NIP-04 encrypted to the wallet, answered by a kind 23195 that tags the request.
//
// The link's secret spends the wallet's money. It is never logged, never put in a URL, and never shown again once
// saved. It is kept sealed in this browser: AES-GCM under a key WebCrypto made non-extractable, both in the
// IndexedDB "haven:<pubkey>:wallet", which sign-out deletes with the account's other stores (vault.js storeNames).
import { Relay } from "nostr-tools/relay"
import { finalizeEvent, getPublicKey } from "nostr-tools/pure"
import { encrypt, decrypt } from "nostr-tools/nip04"
import { hexToBytes } from "nostr-tools/utils"

const HEX64 = /^[0-9a-f]{64}$/
const SCHEME = "nostr+walletconnect:"
/** The iPhone's NWC timeout (NWCService.call). */
export const WALLET_TIMEOUT_MS = 15_000
/** The iPhone's default zap (HavenConfig.defaultZapAmount, 1,000 msat). */
export const DEFAULT_ZAP_SATS = 1

const loopback = host => host === "localhost" || host === "[::1]" || /^127\./.test(host)

/**
 * A nostr+walletconnect link -> { walletPubkey, relay, secret }. Throws a message that never repeats the link,
 * so nothing that shows the error shows the secret.
 */
export function parseWalletUri(input) {
  const s = (input ?? "").trim()
  if (!s.toLowerCase().startsWith(SCHEME)) throw new Error("That isn't a wallet connection. It should start with nostr+walletconnect://")
  let url
  try { url = new URL("nwc://" + s.slice(SCHEME.length).replace(/^\/\//, "")) } catch { url = null }
  const walletPubkey = (url?.hostname || url?.pathname.replace(/^\/+/, "") || "").toLowerCase()
  if (!HEX64.test(walletPubkey)) throw new Error("The wallet connection is missing the wallet's key. Copy it from your wallet again.")
  const relay = (url.searchParams.get("relay") ?? "").trim().replace(/\/+$/, "")
  let relayUrl = null
  try { relayUrl = new URL(relay) } catch {}
  if (!relayUrl || !(relayUrl.protocol === "wss:" || (relayUrl.protocol === "ws:" && loopback(relayUrl.hostname))))
    throw new Error("The wallet connection is missing a secure (wss://) relay. Copy it from your wallet again.")
  const secret = (url.searchParams.get("secret") ?? "").trim().toLowerCase()
  if (!HEX64.test(secret)) throw new Error("The wallet connection is missing its secret. Copy it from your wallet again.")
  return { walletPubkey, relay, secret }
}

/** A NIP-47 error the wallet answered with: `code` tells "this wallet doesn't do that" from a failure. */
export class WalletError extends Error {
  constructor(code, message) { super(message || code); this.code = code }
}

/** No answer in time. For a payment that is not a failure: the wallet may still pay it. */
export class WalletTimeout extends Error {}

/**
 * One NIP-47 request -> its `result`. Opens the link's relay, subscribes for the wallet's answer, sends the request
 * and closes. Only a kind 23195 from the wallet's key that tags this request counts, and the relay checks its
 * signature (nostr-tools Relay verifyEvent).
 */
export async function walletRequest(conn, method, params = {}, { timeoutMs = WALLET_TIMEOUT_MS, connect = url => Relay.connect(url) } = {}) {
  const sk = hexToBytes(conn.secret)
  const request = finalizeEvent({
    kind: 23194, created_at: Math.floor(Date.now() / 1000), tags: [["p", conn.walletPubkey]],
    content: encrypt(sk, conn.walletPubkey, JSON.stringify({ method, params })),
  }, sk)
  let relay
  try { relay = await connect(conn.relay) } catch { throw new Error("Couldn't reach your wallet's relay.") }
  try {
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new WalletTimeout(method === "pay_invoice"
        ? "Your wallet didn't answer in time. The payment may still go through: check your wallet before you zap again."
        : "Your wallet didn't answer in time.")), timeoutMs)
      const done = f => v => { clearTimeout(timer); f(v) }
      relay.subscribe([{ kinds: [23195], authors: [conn.walletPubkey], "#e": [request.id] }], {
        onevent(ev) {
          if (ev.pubkey !== conn.walletPubkey || !ev.tags.some(t => t[0] === "e" && t[1] === request.id)) return
          let answer
          try { answer = JSON.parse(decrypt(sk, conn.walletPubkey, ev.content)) } catch {
            return done(reject)(new Error("Your wallet sent back something this app can't read."))
          }
          if (answer?.error) done(reject)(new WalletError(answer.error.code ?? "OTHER", answer.error.message))
          else done(resolve)(answer?.result ?? {})
        },
        oneose() { relay.publish(request).catch(() => done(reject)(new Error("Your wallet's relay didn't take the request."))) },
      })
    })
  } finally {
    relay.close()
  }
}

/** The wallet's balance in millisats (NIP-47 get_balance). */
export async function getBalance(conn, opts) {
  const { balance } = await walletRequest(conn, "get_balance", {}, opts)
  if (!Number.isFinite(balance)) throw new Error("Your wallet didn't say its balance.")
  return balance
}

/** Pay a bolt11 invoice (NIP-47 pay_invoice) -> the preimage, or "" when the wallet didn't send one. */
export async function payInvoice(conn, invoice, opts) {
  const { preimage } = await walletRequest(conn, "pay_invoice", { invoice }, opts)
  return typeof preimage === "string" ? preimage : ""
}

// Sealing: the link is encrypted under a non-extractable AES-GCM key. Both are kept together, so this hides the
// link from anything that reads the browser's files or copies its storage, not from script running on this page.
export async function sealUri(uri, subtle = crypto.subtle) {
  const key = await subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"])
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const data = await subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(uri))
  return { key, iv, data }
}
export async function openUri(sealed, subtle = crypto.subtle) {
  return new TextDecoder().decode(await subtle.decrypt({ name: "AES-GCM", iv: sealed.iv }, sealed.key, sealed.data))
}

/** The account's wallet store: one record, { sealed?, defaultSats? }. Named so sign-out's store wipe takes it. */
export const walletDbName = pubkey => `haven:${pubkey}:wallet`
export function idbStore(pubkey, idb = globalThis.indexedDB) {
  const open = () => new Promise((resolve, reject) => {
    const req = idb.open(walletDbName(pubkey), 1)
    req.onupgradeneeded = () => req.result.createObjectStore("wallet")
    // Sign-out deletes this database: an open connection lets go rather than block it.
    req.onsuccess = () => { req.result.onversionchange = () => req.result.close(); resolve(req.result) }
    req.onerror = () => reject(req.error)
  })
  const run = (mode, f) => open().then(db => new Promise((resolve, reject) => {
    const tx = db.transaction("wallet", mode), req = f(tx.objectStore("wallet"))
    tx.oncomplete = () => { db.close(); resolve(req.result) }
    tx.onerror = () => { db.close(); reject(tx.error) }
  }))
  return {
    get: () => run("readonly", s => s.get("record")),
    put: v => run("readwrite", s => s.put(v, "record")),
  }
}

// The signed-in account's wallet, for every zap button: { status: "loading" | "none" | "ready", conn?, defaultSats }.
let current = { status: "loading", defaultSats: DEFAULT_ZAP_SATS }
let store = null
const listeners = new Set()
export const walletState = () => current
export function onWallet(f) { listeners.add(f); return () => listeners.delete(f) }
function set(next) { current = next; for (const f of listeners) f(current) }

/** Read the account's saved wallet once per account; every zap button and the Wallet screen call it. */
let loadedFor = null
export function ensureWallet(pubkey) {
  if (!pubkey || loadedFor === pubkey) return
  loadedFor = pubkey
  set({ status: "loading", defaultSats: DEFAULT_ZAP_SATS })
  loadWallet(pubkey).catch(() => set({ status: "none", defaultSats: DEFAULT_ZAP_SATS }))
}

/** Read the account's saved wallet. A record that no longer opens reads as no wallet. */
export async function loadWallet(pubkey, s = idbStore(pubkey)) {
  store = s
  const rec = await s.get().catch(() => null)
  const defaultSats = rec?.defaultSats ?? DEFAULT_ZAP_SATS
  let conn = null
  if (rec?.sealed) try { conn = parseWalletUri(await openUri(rec.sealed)) } catch {}
  set(conn ? { status: "ready", conn, defaultSats } : { status: "none", defaultSats })
}

/** Check the link, seal it and keep it. Throws (without the link in the message) when it doesn't parse. */
export async function connectWallet(uri) {
  const conn = parseWalletUri(uri)
  const rec = (await store.get().catch(() => null)) ?? {}
  await store.put({ ...rec, sealed: await sealUri(uri.trim()) })
  set({ ...current, status: "ready", conn })
}

/** Forget the link. The default amount stays, as on the iPhone. */
export async function disconnectWallet() {
  const rec = (await store.get().catch(() => null)) ?? {}
  await store.put({ defaultSats: rec.defaultSats ?? current.defaultSats })
  set({ status: "none", defaultSats: current.defaultSats })
}

/** The amount a tap on a zap button sends, in whole sats (1 to 10,000,000, the iPhone's limits). */
export async function setDefaultZap(sats) {
  const n = Math.floor(Number(sats))
  if (!(n >= 1 && n <= 10_000_000)) throw new Error("A zap is 1 to 10,000,000 sats.")
  const rec = (await store.get().catch(() => null)) ?? {}
  await store.put({ ...rec, defaultSats: n })
  set({ ...current, defaultSats: n })
}

/** The secret's public key: the identity the wallet knows this app by. Shown so the user can match it in the wallet. */
export const appKeyOf = conn => getPublicKey(hexToBytes(conn.secret))
