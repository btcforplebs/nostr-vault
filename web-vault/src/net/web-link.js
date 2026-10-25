// "Open in …": where a piece of Nostr content lives on the web, so it can be opened in a browser tab and checked off
// the vault. One site per kind of content, the same on every platform. Ported from the iPhone's NostrWebLink
// (HavenApp/HavenApp/Models/NostrWebLink.swift):
//
// - recipes → zap.cooking (`/recipe/<naddr>`)
// - live streams → zap.stream (`/<naddr>`)
// - long-form articles → YakiHonne (`/article/<naddr>`)
// - profiles and trust → Brainstorm (`/p/<nprofile>`)
//
// Links carry `naddr` / `nprofile`, never hex, so any NIP-19 reader can use them.
import { bech32 } from "@scure/base"
import { isRecipe } from "../readers/longform.js"

export const LONG_FORM_KIND = 30023
export const LIVE_STREAM_KIND = 30311
/** At most this many relay hints go in a link, so it stays short enough to paste. */
export const MAX_RELAY_HINTS = 2

/** The site's name as its menu item says it: "Open in zap.cooking". */
export const SITE_NAMES = { recipe: "zap.cooking", liveStream: "zap.stream", article: "YakiHonne", profile: "Brainstorm" }

const link = (type, url) => ({ type, url, site: SITE_NAMES[type] })
const utf8 = s => new TextEncoder().encode(s)
const hexBytes = h => Uint8Array.from(h.match(/../g), b => parseInt(b, 16))
const hexKey = h => (typeof h === "string" && /^[0-9a-fA-F]{64}$/.test(h) ? h.toLowerCase() : null)
// A TLV value carries a one-byte length: Swift's tlvEntry gives nil past 255 bytes.
const fits = s => utf8(s).length <= 255

/** ws(s) relays only, the first two, and (like Swift's encodeTLV) an oversized one still takes its slot but is left out. */
const relayHints = relays => (relays ?? []).filter(r => typeof r === "string" && (r.startsWith("wss://") || r.startsWith("ws://")))
  .slice(0, MAX_RELAY_HINTS).filter(fits)

// TLV entries in the order the Swift writes them (d, relays, author, kind for naddr; key, relays for nprofile), so a
// link is the same string on every platform. nostr-tools' encoders put them in another order: same address,
// different text.
const tlv = (type, bytes) => [type, bytes.length, ...bytes]
const relayEntries = relays => relayHints(relays).flatMap(r => tlv(1, utf8(r)))
const encode = (hrp, bytes) => bech32.encode(hrp, bech32.toWords(Uint8Array.from(bytes)), 5000)

export function naddr(kind, pubkey, identifier, relays = []) {
  const pk = hexKey(pubkey)
  if (!pk || !Number.isInteger(kind) || kind < 0 || kind > 0xffffffff || typeof identifier !== "string" || !fits(identifier)) return null
  const kindBytes = [kind >>> 24, (kind >>> 16) & 255, (kind >>> 8) & 255, kind & 255]
  return encode("naddr", [...tlv(0, utf8(identifier)), ...relayEntries(relays), ...tlv(2, hexBytes(pk)), ...tlv(3, kindBytes)])
}

export function nprofile(pubkey, relays = []) {
  const pk = hexKey(pubkey)
  return pk ? encode("nprofile", [...tlv(0, hexBytes(pk)), ...relayEntries(relays)]) : null
}

const dTag = tags => (tags ?? []).find(t => t.length >= 2 && t[0] === "d")?.[1]

/** A long-form post: a recipe when its tags say so, else an article. Null for any other kind or without a `d` tag,
 *  since an naddr needs one. -> { type, url, site } */
export function longFormLink(kind, pubkey, tags) {
  const d = dTag(tags)
  const a = kind === LONG_FORM_KIND && d != null ? naddr(kind, pubkey, d) : null
  if (!a) return null
  return isRecipe(tags) ? link("recipe", `https://zap.cooking/recipe/${a}`) : link("article", `https://yakihonne.com/article/${a}`)
}

/** A NIP-53 stream, addressed by who signed it (not the host), with the stream's own relays as hints. */
export function liveStreamLink(authorPubkey, identifier, relays = []) {
  const a = naddr(LIVE_STREAM_KIND, authorPubkey, identifier, relays)
  return a ? link("liveStream", `https://zap.stream/${a}`) : null
}

export function profileLink(pubkey) {
  const p = nprofile(pubkey)
  return p ? link("profile", `https://brainstorm.world/p/${p}`) : null
}

/** The post's link, when it is a kind that has a place on the web (articles and recipes): FeedNote.webLink. */
export const eventWebLink = ev => (ev ? longFormLink(ev.kind, ev.pubkey, ev.tags) : null)
