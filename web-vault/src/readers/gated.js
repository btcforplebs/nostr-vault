// Locked (gated) long-form articles: the body is sold for a zap and ships encrypted, with only a teaser in
// `content`. The web shows the teaser and a lock card with a link out, never a payment (the iPhone's GatedArticle,
// GatedArticleTeaser and GatedLockCopy). Unlocking (NIP-98 key request, AES-GCM) is not on the web.
import { naddrEncode } from "nostr-tools/nip19"

const HEX64 = /^[0-9a-f]{64}$/i

/** { priceSats, keyUrl, isFanfares, relay } for a gated article we recognise, else null: kind 30023 with an
 *  `encrypted` aes-256-gcm tag naming an https key URL, and a positive price in sats. */
export function gatedArticle(ev) {
  const tags = ev?.tags ?? []
  if (ev?.kind !== 30023) return null
  const enc = tags.find(t => t[0] === "encrypted")
  if (!enc || enc.length < 4 || String(enc[1]).toLowerCase() !== "aes-256-gcm" || !enc[2]) return null
  let keyUrl
  try { keyUrl = new URL(enc[3]) } catch { return null }
  if (keyUrl.protocol !== "https:") return null
  const price = tags.find(t => t[0] === "price" && t.length >= 2)
  const amount = price && /^\s*\d+\s*$/.test(price[1]) ? Number(price[1]) : 0
  if (!(amount > 0)) return null
  // Only sats are something a zap can pay; a fiat price isn't treated as gated.
  const currency = price.length >= 3 ? String(price[2]).toUpperCase() : "SATS"
  if (currency !== "SATS" && currency !== "SAT") return null
  const host = keyUrl.hostname.toLowerCase()
  const isFanfares = ["fanfares.live", "fanfares.io"].some(h => host === h || host.endsWith("." + h))
  return { priceSats: amount, keyUrl: keyUrl.href, isFanfares, relay: shareRelay(ev.pubkey, tags) }
}

// The naddr's relay hint, as the iPhone picks it: the author's own `zap` tag relay, else the first named one.
function shareRelay(pubkey, tags) {
  const zaps = tags.filter(t => t[0] === "zap" && t.length >= 3 && HEX64.test(t[1] ?? "") && t[2])
  return zaps.find(t => t[1].toLowerCase() === pubkey)?.[2] ?? zaps[0]?.[2] ?? null
}

const ctaLine = lines => {
  for (let i = lines.length - 1; i >= 0; i--) if (/to unlock/i.test(lines[i])) return i
  return -1
}

/** The teaser without its "zap N sats to unlock … <link>" call to action, which the lock card replaces. */
export function stripTeaser(content) {
  const lines = String(content ?? "").split(/\r?\n|\r/)
  const cta = ctaLine(lines)
  return cta < 0 ? String(content ?? "") : lines.slice(0, cta).join("\n").trim()
}

/** The author's own link to the article: the first URL on or after the call-to-action line. */
export function teaserUnlockUrl(content) {
  const lines = String(content ?? "").split(/\r?\n|\r/)
  const cta = ctaLine(lines)
  if (cta < 0) return null
  return /https:\/\/[^\s)\]]+/.exec(lines.slice(cta).join("\n"))?.[0] ?? null
}

/** Where to read or buy the article: Fanfares by naddr (with the relay hint, so the string matches Fanfares' own),
 *  else the teaser's link. Null for a gated article that isn't Fanfares'. */
export function fanfaresLink(ev, gated = gatedArticle(ev)) {
  if (!gated?.isFanfares) return null
  const identifier = ev.tags.find(t => t[0] === "d" && t.length >= 2)?.[1]
  if (identifier != null && HEX64.test(ev.pubkey ?? "")) {
    const naddr = naddrEncode({ kind: ev.kind, pubkey: ev.pubkey, identifier, relays: gated.relay ? [gated.relay] : [] })
    return `https://fanfares.io/naddr/${naddr}`
  }
  return teaserUnlockUrl(ev.content)
}

/** The lock card's sentence. */
export const lockStatus = (author, isFanfares) => isFanfares
  ? `Locked by ${author}. Unlock it on Fanfares to read it.`
  : `Locked by ${author}. Only its unlocked readers can open it.`
