// Send from the connected wallet, as the iPhone does (WalletLightningTab+Send, +LNURL; LightningPayTarget,
// LNURLAmountRange): one box takes a bolt11 invoice, a lightning address, a bech32 LNURL or an LUD-17 lnurlp:// link,
// bare or behind lightning: or inside a BIP21 bitcoin: link. THIS SPENDS MONEY: every path ends in pay_invoice, and
// only after the screen has shown the amount and the user has confirmed it.
import { decodeLnurl, invoiceMsat, isAllowedEndpoint } from "./zaps.js"
import { payInvoice } from "./wallet.js"

/**
 * What was pasted -> { kind: "invoice", invoice } | { kind: "address", address } | { kind: "lnurl", url }, or null
 * for anything this wallet can't pay. Lower-cased, wrapping removed (LightningPayTarget.parse).
 */
export function parsePayTarget(raw) {
  let text = (raw ?? "").trim()
  if (!text) return null
  // BIP21: bitcoin:addr?amount=…&lightning=lnbc… — the lightning parameter is the part this wallet can pay.
  if (/^bitcoin:/i.test(text)) {
    const query = text.split("?")[1] ?? ""
    const pair = query.split("&").find(p => /^lightning=/i.test(p))
    if (!pair) return null
    text = pair.slice("lightning=".length)
    try { text = decodeURIComponent(text) } catch {}
  }
  if (/^lightning:/i.test(text)) text = text.slice("lightning:".length).replace(/^\/+/, "")
  text = text.trim()
  const lower = text.toLowerCase()
  if (lower.startsWith("lnurlp://")) {
    // LUD-17: onion hosts stay on http, everything else is https.
    const rest = text.slice("lnurlp://".length)
    const host = rest.split("/")[0].toLowerCase()
    let url
    try { url = new URL((host.endsWith(".onion") ? "http://" : "https://") + rest) } catch { return null }
    return url.host ? { kind: "lnurl", url: url.href } : null
  }
  if (lower.startsWith("lnurlw://")) return { kind: "withdraw" }
  if (lower.startsWith("lnurl1")) {
    const url = decodeLnurl(lower)
    return url ? { kind: "lnurl", url } : null
  }
  // Before the invoice test: lntbob@getalby.com is an address.
  if (isLightningAddress(lower)) return { kind: "address", address: lower }
  if ((lower.startsWith("lnbc") || lower.startsWith("lntb")) && !lower.includes("@")) return { kind: "invoice", invoice: lower }
  return null
}

/** name@domain.tld with nothing the well-known URL couldn't carry (LightningPayTarget.isLightningAddress). */
export function isLightningAddress(s) {
  const parts = s.split("@")
  if (parts.length !== 2) return false
  const [name, domain] = parts
  return !!name && domain.includes(".") && !domain.startsWith(".") && !domain.endsWith(".") &&
    /^[a-z0-9\-_.+]+$/.test(name) && /^[a-z0-9\-.:]+$/.test(domain)
}

/** What an invoice will cost: { sats } | { unspecified: true } | { unreadable: true } (Bolt11.amount). */
export function invoiceAmount(invoice) {
  const msat = invoiceMsat(invoice)
  if (msat != null) return { sats: Math.floor(msat / 1000) }
  // No amount digits before the separator: an amountless invoice. Anything else unreadable.
  return /^ln(bcrt|bc|tbs|tb)1[02-9ac-hj-np-z]+$/.test((invoice ?? "").trim().toLowerCase()) ? { unspecified: true } : { unreadable: true }
}

/** The range an LNURL service takes, in whole sats, and whether `sats` fits it (LNURLAmountRange.check). */
export function checkAmount({ minMsat, maxMsat }, sats) {
  const minSats = Math.ceil(minMsat / 1000), maxSats = Math.floor(maxMsat / 1000)
  // A range with no whole sat in it (2,500 msat fixed; 500 to 900 msat): nothing typed can fit, so say that once
  // instead of "too small" and "too large" for neighbouring numbers. iOS LNURLAmountRange has the same gap.
  if (minSats > maxSats) return { unpayable: true, minSats, maxSats }
  if (!(Number.isInteger(sats) && sats > 0)) return { invalid: true, minSats, maxSats }
  if (sats > maxSats) return { tooLarge: true, minSats, maxSats }
  if (sats * 1000 < minMsat) return { tooSmall: true, minSats, maxSats }
  return { ok: true, msat: sats * 1000, minSats, maxSats }
}

// LUD-01 rules for every request: https (or http to an onion), checked again after redirects.
async function lnurlGet(u, fetchImpl) {
  if (!isAllowedEndpoint(u)) throw new Error("It doesn't use a secure (https) connection, so the wallet won't pay it.")
  const res = await fetchImpl(u, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(10_000) })
  if (res.url && !isAllowedEndpoint(res.url)) throw new Error("It redirected to an insecure address, so the wallet won't pay it.")
  const body = await res.json().catch(() => null)
  if (body?.status?.toUpperCase?.() === "ERROR") throw new Error(`The service said: ${String(body.reason ?? "no").slice(0, 200)}`)
  if (!res.ok || !body) throw new Error("The service didn't answer properly.")
  return body
}

/** The text/plain line of an LNURL pay request's metadata, or null. */
export function plainMetadata(metadata) {
  try { return JSON.parse(metadata).find(e => Array.isArray(e) && e[0] === "text/plain" && e[1])?.[1] ?? null } catch { return null }
}

/**
 * An address or LNURL -> its pay request { callback, minMsat, maxMsat, commentAllowed, note, host }. A withdraw link
 * says so: receiving from one isn't on the web yet.
 */
export async function resolvePayTarget(target, fetchImpl = globalThis.fetch) {
  if (target?.kind === "withdraw") throw new Error("That's a link to receive money (LNURL-withdraw). The web wallet can't take those yet.")
  let url
  if (target?.kind === "address") {
    const [name, domain] = target.address.split("@")
    url = `https://${domain}/.well-known/lnurlp/${encodeURIComponent(name)}`
  } else if (target?.kind === "lnurl") url = target.url
  else throw new Error("Not something this wallet can pay.")
  const p = await lnurlGet(url, fetchImpl)
  if (p.tag === "withdrawRequest") throw new Error("That's a link to receive money (LNURL-withdraw). The web wallet can't take those yet.")
  if (p.tag !== "payRequest" || typeof p.callback !== "string") throw new Error("It isn't set up to receive payments.")
  const minMsat = Number(p.minSendable), maxMsat = Number(p.maxSendable)
  if (!(minMsat > 0 && maxMsat >= minMsat)) throw new Error("It didn't say what amounts it takes.")
  return {
    callback: p.callback, minMsat, maxMsat, commentAllowed: Math.max(0, Math.floor(Number(p.commentAllowed) || 0)),
    note: plainMetadata(p.metadata), host: new URL(url).host,
  }
}

/**
 * Pay an LNURL pay request `sats` (with an optional comment): fetch its invoice, and pay it only if it asks for
 * exactly that amount (LUD-06: a service that swaps it is broken or stealing). -> { preimage }
 */
export async function payLnurl(conn, pay, { sats, comment = "" }, { fetchImpl = globalThis.fetch, pay: payImpl = payInvoice } = {}) {
  const check = checkAmount(pay, sats)
  if (check.unpayable) throw new Error("It only takes amounts that aren't a whole number of sats, so this wallet can't pay it.")
  if (!check.ok) throw new Error(`It takes ${check.minSats.toLocaleString()} to ${check.maxSats.toLocaleString()} sats.`)
  const cb = new URL(pay.callback)
  cb.searchParams.set("amount", String(check.msat))
  const words = comment.trim().slice(0, pay.commentAllowed)
  if (words) cb.searchParams.set("comment", words)
  const { pr } = await lnurlGet(cb.href, fetchImpl)
  if (invoiceMsat(pr) !== check.msat) throw new Error(`${pay.host} sent an invoice for a different amount, so nothing was sent.`)
  return { preimage: await payImpl(conn, pr) }
}

/** Pay a pasted bolt11 as it is. The wallet is the authority on whether it can. -> { preimage } */
export async function payBolt11(conn, invoice, { pay: payImpl = payInvoice } = {}) {
  return { preimage: await payImpl(conn, invoice) }
}
