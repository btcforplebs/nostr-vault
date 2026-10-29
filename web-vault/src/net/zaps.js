// Zaps (NIP-57), as the iPhone app sends them (ZapService.zapNote, LNURLService): the recipient's lightning address
// -> their LNURL pay endpoint -> a kind 9734 zap request signed by the user -> an invoice from the endpoint -> paid
// by the connected wallet (net/wallet.js). Totals are the kind 9735 receipts that tag a note, as the iPhone counts
// them (PostEngagementQuery), a receipt from anyone but the recipient's own zap service left out (ZapValidationService).
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, isLoopback, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"
import { getProfile } from "./profiles.js"
import { bolt11Sats, zapRequest } from "./notifications.js"
import { payInvoice, walletState } from "./wallet.js"

const HEX64 = /^[0-9a-f]{64}$/
/** The iPhone's limits (ZapService.zapNote). */
export const MAX_ZAP_SATS = 10_000_000
export const ZAP_MESSAGE = "Zap from Nostr Vault"
/** The iPhone's quick amounts (CustomZapSheet). */
export const PRESET_SATS = [21, 100, 500, 1_000, 5_000, 10_000, 50_000]

/** A profile's lightning address: lud06 first, as the iPhone reads it (FeedActions.getLightningAddress). */
export function lightningOf(profile) {
  const lud06 = (profile?.lud06 ?? "").trim(), lud16 = (profile?.lud16 ?? "").trim()
  if (lud06) return { lud06: lud06.toLowerCase() }
  if (lud16) return { lud16 }
  return null
}

// LUD-01: only https, or plain http to a Tor onion service. Anything else could be rewritten on the way, and an
// invoice swapped for the same amount pays someone else (LNURLService.isAllowedEndpoint).
export function isAllowedEndpoint(u) {
  let url
  try { url = new URL(u) } catch { return false }
  return url.protocol === "https:" || (url.protocol === "http:" && url.hostname.endsWith(".onion"))
}

const B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
function polymod(values) {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
  let chk = 1
  for (const v of values) {
    const top = chk >>> 25
    chk = ((chk & 0x1ffffff) << 5) ^ v
    for (let i = 0; i < 5; i++) if ((top >>> i) & 1) chk ^= G[i]
  }
  return chk
}
/** A bech32 LNURL (lud06) -> the URL inside it, checksum checked; null when it isn't one. */
export function decodeLnurl(s) {
  const str = (s ?? "").trim().toLowerCase().replace(/^lightning:/, "")
  const sep = str.lastIndexOf("1")
  if (str.slice(0, sep) !== "lnurl" || str.length - sep < 7) return null
  const data = [...str.slice(sep + 1)].map(c => B32.indexOf(c))
  if (data.includes(-1)) return null
  const hrp = [...str.slice(0, sep)].map(c => c.charCodeAt(0))
  if (polymod([...hrp.map(c => c >> 5), 0, ...hrp.map(c => c & 31), ...data]) !== 1) return null
  let acc = 0, bits = 0
  const bytes = []
  for (const v of data.slice(0, -6)) {
    acc = (acc << 5) | v; bits += 5
    while (bits >= 8) { bits -= 8; bytes.push((acc >> bits) & 255) }
  }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(bytes)) } catch { return null }
}

/**
 * A person's lightning address from their newest kind 0: Haven /feed first, then their profile relays. The profile
 * cache only keeps lud16, and lud06 comes first. -> { lud06 } | { lud16 } | null
 */
export async function lightningAddressOf(ctx, pubkey, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const newest = evs => evs.filter(e => e?.kind === 0 && e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)[0]
  let ev = newest(await ctx.vault.feed.query({ kinds: [0], authors: [pubkey] }).catch(() => []))
  if (!ev && globalThis.navigator?.onLine !== false)
    ev = newest(await query(uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { kinds: [0], authors: [pubkey] }, { maxWait: 6000 }).catch(() => []))
  let content = null
  try { content = JSON.parse(ev?.content ?? "null") } catch {}
  return lightningOf(content ?? getProfile(pubkey))
}

/** The LNURL pay endpoint behind a lightning address, or null. */
export function payEndpoint(ln) {
  if (ln?.lud06) return decodeLnurl(ln.lud06)
  const [name, domain, extra] = (ln?.lud16 ?? "").split("@")
  if (!name || !domain || extra !== undefined || !/^[a-z0-9.-]+$/i.test(domain)) return null
  return `https://${domain.toLowerCase()}/.well-known/lnurlp/${encodeURIComponent(name.toLowerCase())}`
}

// Every LNURL request goes through here: the URL asked for and the one it ended on after redirects.
async function getJson(u, fetchImpl) {
  if (!isAllowedEndpoint(u)) throw new Error("Their zap service doesn't use a secure (https) connection, so the wallet won't pay it.")
  const res = await fetchImpl(u, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(10_000) })
  if (res.url && !isAllowedEndpoint(res.url)) throw new Error("Their zap service redirected to an insecure address, so the wallet won't pay it.")
  const body = await res.json().catch(() => null)
  if (body?.status?.toUpperCase?.() === "ERROR") throw new Error(`Their zap service said: ${String(body.reason ?? "no").slice(0, 200)}`)
  if (!res.ok || !body) throw new Error("Their zap service didn't answer properly.")
  return body
}

/** The LNURL pay request for a lightning address -> { callback, minMsat, maxMsat, nostrPubkey, lnurl }. */
export async function resolvePay(ln, fetchImpl = globalThis.fetch) {
  const url = payEndpoint(ln)
  if (!url) throw new Error("Their lightning address isn't one this app can read.")
  const p = await getJson(url, fetchImpl)
  if (p.tag !== "payRequest" || typeof p.callback !== "string") throw new Error("Their lightning address isn't set up to receive payments.")
  return {
    callback: p.callback, minMsat: Number(p.minSendable) || 1000, maxMsat: Number(p.maxSendable) || MAX_ZAP_SATS * 1000,
    nostrPubkey: p.allowsNostr && HEX64.test(p.nostrPubkey ?? "") ? p.nostrPubkey : null,
    lnurl: ln.lud06 ?? ln.lud16,
  }
}

/** The exact millisats an invoice asks for, or null for an amountless or unreadable one (Bolt11.msat). */
export function invoiceMsat(invoice) {
  const s = (invoice ?? "").trim().toLowerCase()
  const sep = s.lastIndexOf("1")
  const m = /^ln(?:bcrt|bc|tbs|tb)(\d+)([munp]?)$/.exec(s.slice(0, sep))
  if (!m) return null
  const v = BigInt(m[1])
  const msat = { "": v * 100_000_000_000n, m: v * 100_000_000n, u: v * 100_000n, n: v * 100n, p: v % 10n ? -1n : v / 10n }[m[2]]
  return msat > 0n && msat < 21_000_000n * 100_000_000_000n ? Number(msat) : null
}

const isPublicRelay = u => {
  let h
  try { h = new URL(u).hostname.toLowerCase() } catch { return false }
  if (isLoopback(u) || h.endsWith(".local")) return false
  const o = h.split(".").map(Number)
  if (o.length === 4 && o.every(Number.isInteger))
    return !(o[0] === 10 || o[0] === 0 || (o[0] === 192 && o[1] === 168) || (o[0] === 169 && o[1] === 254) ||
      (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || (o[0] === 100 && o[1] >= 64 && o[1] <= 127))
  return true
}

/** Where the zap service should publish the receipt: relays it can reach and that get read (ZapService.receiptRelays). */
export const receiptRelays = account =>
  uniq([...account.relays.read, ...account.relays.write, ...DEFAULT_RELAYS].map(u => u.trim().replace(/\/+$/, ""))).filter(isPublicRelay).slice(0, 10)

/** The kind 9734 zap request, tagged as the iPhone tags it. A profile zap has no `e` tag. */
export const zapRequestTemplate = ({ recipient, noteId, address, amountMsat, relays, lnurl, content = ZAP_MESSAGE }) => ({
  kind: 9734, created_at: Math.floor(Date.now() / 1000), content,
  tags: [["p", recipient], ["relays", ...relays], ["amount", String(amountMsat)], ...(noteId ? [["e", noteId]] : []), ...(address ? [["a", address]] : []), ["lnurl", lnurl]],
})

/**
 * Zap `recipient` (and `note`, when it is a note zap) `sats` from the connected wallet. Nothing is paid unless the
 * invoice asks for exactly the amount the user chose. -> { preimage }
 */
export async function zap(ctx, { recipient, note, sats, address, comment }, { fetchImpl = globalThis.fetch, pay = payInvoice, wallet = walletState(), lnOf = pk => lightningAddressOf(ctx, pk) } = {}) {
  if (wallet.status !== "ready") throw new Error("Connect a wallet first.")
  if (!(Number.isInteger(sats) && sats >= 1 && sats <= MAX_ZAP_SATS)) throw new Error("A zap is 1 to 10,000,000 sats.")
  const ln = await lnOf(recipient)
  if (!ln) throw new Error("They haven't set up a lightning address.")
  const amountMsat = sats * 1000
  const lnurl = await resolvePay(ln, fetchImpl)
  if (amountMsat < lnurl.minMsat || amountMsat > lnurl.maxMsat)
    throw new Error(`Their zap service takes ${Math.ceil(lnurl.minMsat / 1000)} to ${Math.floor(lnurl.maxMsat / 1000)} sats.`)
  // `address`: a live stream's (NIP-53), so its chat shows the zap and names the payer; `comment`, said with it.
  const template = zapRequestTemplate({ recipient, noteId: note?.id, address, amountMsat, relays: receiptRelays(ctx.account), lnurl: lnurl.lnurl, ...(comment?.trim() ? { content: comment.trim() } : {}) })
  const request = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const cb = new URL(lnurl.callback)
  cb.searchParams.set("amount", String(amountMsat))
  cb.searchParams.set("nostr", JSON.stringify(request))
  cb.searchParams.set("lnurl", lnurl.lnurl)
  const { pr } = await getJson(cb.href, fetchImpl)
  if (invoiceMsat(pr) !== amountMsat) throw new Error("Their zap service sent an invoice for a different amount, so nothing was paid.")
  const preimage = await pay(wallet.conn, pr)
  if (note?.id) markZapped(note.id, sats)
  return { preimage }
}

// Totals per note: { sats, mine } from the receipts seen, plus what this browser just zapped. One store, so the same
// note shown twice reads the same. Cards ask through wantTotals; asks within a moment go out together.
const totals = new Map()
const seen = new Map() // note id -> Set of receipt ids already counted
const zappers = new Map() // note id -> [{ id, sender, sats, comment, created_at }], from receipts with a valid zap request
const listeners = new Set()
export const zapTotal = id => totals.get(id) ?? { sats: 0, mine: false }
/** Who zapped note `id` (ZappersListView): biggest first, then newest. */
export const zappersOf = id => [...(zappers.get(id) ?? [])].sort((a, b) => b.sats - a.sats || b.created_at - a.created_at)
export function onZapTotals(f) { listeners.add(f); return () => listeners.delete(f) }
function add(id, sats, mine) {
  const t = zapTotal(id)
  totals.set(id, { sats: t.sats + sats, mine: t.mine || mine })
  for (const f of listeners) f(id)
}
function markZapped(id, sats) { add(id, sats, true) }

// The pubkey a recipient's zap service publishes receipts with, once per session; null when it can't be known.
const publishers = new Map()
function publisherOf(recipient, lnOf, fetchImpl) {
  if (!publishers.has(recipient))
    publishers.set(recipient, lnOf(recipient).then(ln => ln ? resolvePay(ln, fetchImpl).then(p => p.nostrPubkey) : null).catch(() => null))
  return publishers.get(recipient)
}

/**
 * Count the receipts in `events` toward the notes in `ids`. A receipt counts once, on the note its `e` tag names,
 * for the sats its invoice states; one published by anyone but the recipient's zap service is skipped. Like the
 * iPhone, a recipient whose zap service can't be resolved is trusted (fails open).
 */
export async function countReceipts(events, ids, me, lnOf, fetchImpl = globalThis.fetch) {
  const want = new Set(ids)
  for (const ev of events) {
    if (ev?.kind !== 9735) continue
    const target = ev.tags.find(t => t[0] === "e" && want.has(t[1]))?.[1]
    const recipient = ev.tags.find(t => t[0] === "p" && HEX64.test(t[1] ?? ""))?.[1]
    const sats = bolt11Sats(ev.tags.find(t => t[0] === "bolt11")?.[1])
    if (!target || !recipient || sats <= 0) continue
    if (!seen.has(target)) seen.set(target, new Set())
    const counted = seen.get(target)
    if (counted.has(ev.id)) continue
    const publisher = await publisherOf(recipient, lnOf, fetchImpl)
    if (publisher && publisher !== ev.pubkey) continue
    if (counted.has(ev.id)) continue // counted while the publisher was being resolved
    counted.add(ev.id)
    // Who zapped is the zap request's signer, never the receipt's publisher; a receipt without a valid request still
    // counts toward the total (as on the iPhone) but names nobody in the list.
    const req = zapRequest(ev)
    if (req) {
      if (!zappers.has(target)) zappers.set(target, [])
      zappers.get(target).push({ id: ev.id, sender: req.pubkey, sats, comment: (req.content ?? "").trim(), created_at: ev.created_at })
    }
    add(target, sats, req?.pubkey === me)
  }
}

/**
 * `events` without the zap receipts their payee's zap service didn't publish (the iPhone's ZapValidationService):
 * the receipt's author must be the `nostrPubkey` of the LNURL endpoint in the payee's profile, and its zap request
 * must hold up (notifications.js zapRequest). Other kinds pass untouched. As countReceipts does, a payee whose zap
 * service can't be resolved is trusted (fails open) for the author check; the request check never fails open.
 */
export async function trustedReceipts(events, lnOf, fetchImpl = globalThis.fetch) {
  const payeeOf = ev => ev.tags.find(t => t[0] === "p" && HEX64.test(t[1] ?? ""))?.[1]
  // Every payee's zap service at once, a few at a time, not one after another: each is a profile read and an LNURL
  // request, and 60 payees in turn took ~20 s.
  const payees = [...new Set(events.filter(ev => ev?.kind === 9735 && zapRequest(ev)).map(payeeOf))]
  const next = payees.values()
  await Promise.all(Array.from({ length: Math.min(TRUST_PARALLEL, payees.length) }, async () => {
    for (const payee of next) await publisherOf(payee, lnOf, fetchImpl)
  }))
  const out = []
  for (const ev of events) {
    if (ev?.kind !== 9735) { out.push(ev); continue }
    if (!zapRequest(ev)) continue
    const payee = payeeOf(ev)
    const publisher = await publisherOf(payee, lnOf, fetchImpl)
    if (publisher && publisher !== ev.pubkey) continue
    out.push(ev)
  }
  return out
}
/** How many payees' zap services trustedReceipts asks at once. */
export const TRUST_PARALLEL = 8
/** The zap service pubkey that publishes `recipient`'s receipts (their LNURL's nostrPubkey), or null when it doesn't
 *  resolve. Asked once per recipient per session. */
export const zapPublisherOf = (ctx, recipient, fetchImpl = globalThis.fetch) => publisherOf(recipient, pk => lightningAddressOf(ctx, pk), fetchImpl)
/** trustedReceipts for this account's screens. */
export const receiptTrust = ctx => evs => trustedReceipts(evs, pk => lightningAddressOf(ctx, pk))

let queue = new Set(), timer = null
/** Ask for `id`'s zap total from the account's read relays. Asked once per note per session. */
export function wantTotals(ctx, id, { query = (r, f, o) => pool.querySync(r, f, o), delayMs = 300 } = {}) {
  if (!HEX64.test(id ?? "") || seen.has(id)) return
  seen.set(id, new Set())
  queue.add(id)
  timer ??= setTimeout(async () => {
    const ids = [...queue]
    queue = new Set(); timer = null
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])
    // Small groups: a relay applies `limit` per filter, and one filter per call (pool wraps it in the REQ itself).
    for (let i = 0; i < ids.length; i += 10) {
      const group = ids.slice(i, i + 10)
      const evs = await query(relays, { kinds: [9735], "#e": group, limit: 500 }, { maxWait: 6000 }).catch(() => [])
      await countReceipts(evs, group, ctx.session.pubkey, pk => lightningAddressOf(ctx, pk, { query })).catch(() => {})
    }
  }, delayMs)
}
