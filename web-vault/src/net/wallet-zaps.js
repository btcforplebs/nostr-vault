// Zaps in wallet History that the wallet didn't echo (the iPhone's ZapHistoryService and ZapReceipt): most wallets
// return a plain description, so the zap is found from its public receipt (kind 9735) instead, matched to the payment
// by payment hash, else by the invoice. Then the zapped posts, for the "on: …" line and tap-to-open. Reading only.
//
// A receipt is anyone's event until proven otherwise. It is believed only when it is signed, the zap request inside
// it is signed, and it was published by the key the zapped person's own LNURL service names (nostrPubkey). Without the
// last check anyone could copy a real receipt's bolt11 into one of their own and put any sender, post or comment
// ("refund me at …") on your payment. Unlike counting zap totals, this fails closed: no service key, no story.
import { verifyEvent } from "nostr-tools/pure"
import { zapDetailOf } from "./wallet-history.js"

const HEX64 = /^[0-9a-f]{64}$/
// Only the signed fields: verifyEvent trusts a cached "verified" flag that a copied or tampered object can carry.
const signed = ev => { try { const { id, pubkey, created_at, kind, tags, content, sig } = ev; return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false } }

// --- bolt11: just enough to read the payment hash (BOLT 11 tagged field `p`), with the bech32 checksum checked.
const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
function polymod(values) {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
  let chk = 1
  for (const v of values) { const b = chk >>> 25; chk = ((chk & 0x1ffffff) << 5) ^ v; for (let i = 0; i < 5; i++) if ((b >>> i) & 1) chk ^= G[i] }
  return chk
}
function bech32Words(s) {
  const str = String(s ?? "").trim().toLowerCase()
  const at = str.lastIndexOf("1")
  if (at < 1 || at + 7 > str.length) return null
  const hrp = str.slice(0, at), words = []
  for (const c of str.slice(at + 1)) { const v = CHARSET.indexOf(c); if (v < 0) return null; words.push(v) }
  const expand = [...[...hrp].map(c => c.charCodeAt(0) >> 5), 0, ...[...hrp].map(c => c.charCodeAt(0) & 31)]
  if (polymod([...expand, ...words]) !== 1) return null
  return { hrp, words: words.slice(0, -6) }
}
const wordsToHex = (words, bytes) => {
  let acc = 0, bits = 0, out = ""
  for (const w of words) { acc = (acc << 5) | w; bits += 5; while (bits >= 8 && out.length < bytes * 2) { bits -= 8; out += ((acc >> bits) & 255).toString(16).padStart(2, "0") } acc &= (1 << bits) - 1 }
  return out.length === bytes * 2 ? out : null
}

/** The payment hash a bolt11 invoice carries, as hex, or null. */
export function paymentHashOf(invoice) {
  const d = bech32Words(invoice)
  if (!d || !d.hrp.startsWith("ln") || d.words.length < 7 + 104) return null
  const data = d.words.slice(7, -104) // after the timestamp, before the signature
  for (let i = 0; i + 3 <= data.length;) {
    const type = data[i], len = data[i + 1] * 32 + data[i + 2]
    if (type === 1 && len === 52) return wordsToHex(data.slice(i + 3, i + 3 + 52), 32)
    i += 3 + len
  }
  return null
}

/** A receipt's tags -> { paymentHash, bolt11, detail } (the zap request read by wallet-history.js zapDetailOf), or null. */
export function receiptOf(ev) {
  const tag = name => ev?.tags?.find(t => t.length >= 2 && t[0] === name)?.[1]
  const bolt11 = tag("bolt11")?.toLowerCase()
  const detail = zapDetailOf(tag("description") ?? "")
  if (!bolt11 || !detail) return null
  return { paymentHash: paymentHashOf(bolt11), bolt11, detail }
}

const same = (a, b) => a.sender === b.sender && a.recipient === b.recipient && a.noteId === b.noteId && a.comment === b.comment && a.anonymous === b.anonymous

/** Each transaction's zap from the receipts: by payment hash when both sides have one, else by the invoice text. Two
 *  receipts telling different stories about one payment mean at least one is forged: that payment gets neither.
 *  A transaction's hash or invoice is its id (wallet-history.js parseTransaction). -> Map(txId -> detail) */
export function matchReceipts(txs, receipts) {
  const byHash = new Map(), byInvoice = new Map(), badHash = new Set(), badInvoice = new Set()
  for (const r of receipts) {
    if (r.paymentHash) { const seen = byHash.get(r.paymentHash); if (seen && !same(seen, r.detail)) badHash.add(r.paymentHash); byHash.set(r.paymentHash, r.detail) }
    const seen = byInvoice.get(r.bolt11); if (seen && !same(seen, r.detail)) badInvoice.add(r.bolt11); byInvoice.set(r.bolt11, r.detail)
  }
  const out = new Map()
  for (const tx of txs) {
    const id = String(tx.id ?? "").toLowerCase()
    const hash = HEX64.test(id) ? id : /^ln/.test(id) ? paymentHashOf(id) : null
    if (hash && byHash.has(hash)) { if (!badHash.has(hash)) out.set(tx.id, byHash.get(hash)) }
    else if (/^ln/.test(id) && byInvoice.has(id) && !badInvoice.has(id)) out.set(tx.id, byInvoice.get(id))
  }
  return out
}

/** Receipt filters for the time a page covers: receipts are published when paid, which can be a while after the
 *  invoice was made. */
export function receiptFilters(txs, me) {
  const times = txs.map(t => t.created_at)
  const since = Math.min(...times) - 600, until = Math.max(...times) + 3600
  return [{ kinds: [9735], "#p": [me], since, until, limit: 500 }, { kinds: [9735], "#P": [me], since, until, limit: 500 }]
}

/**
 * Zaps for the transactions the wallet didn't explain, and the zapped posts. `query(relays, filter)` reads relays;
 * `publisherOf(pubkey)` resolves the key their LNURL service publishes receipts with (null when there is none);
 * `fits(detail, direction)` keeps only zaps that involve you. -> { details: Map(txId -> detail), posts: Map(id -> event) }
 */
export async function lookupZaps(txs, me, { relays, query, publisherOf, fits }) {
  const details = new Map(), posts = new Map()
  const unresolved = txs.filter(t => !t.zap)
  if (!me || !unresolved.length) return { details, posts }
  const evs = (await Promise.all(receiptFilters(unresolved, me).map(f => query(relays, f).catch(() => [])))).flat()
  const seen = new Set(), receipts = []
  for (const ev of evs) {
    if (ev?.kind !== 9735 || seen.has(ev.id)) continue
    seen.add(ev.id)
    const r = receiptOf(ev)
    if (!r?.detail.recipient || !signed(ev)) continue
    const publisher = await publisherOf(r.detail.recipient).catch(() => null)
    if (publisher && publisher === ev.pubkey) receipts.push(r)
  }
  const byId = new Map(unresolved.map(t => [t.id, t]))
  for (const [id, d] of matchReceipts(unresolved, receipts)) if (fits(d, byId.get(id).direction)) details.set(id, d)
  const ids = [...new Set([...txs.map(t => t.zap?.noteId), ...[...details.values()].map(d => d.noteId)].filter(Boolean))]
  if (ids.length) {
    for (const ev of await query(relays, { ids, limit: ids.length }).catch(() => []))
      if (ids.includes(ev?.id) && !posts.has(ev.id) && signed(ev)) posts.set(ev.id, ev)
  }
  return { details, posts }
}
