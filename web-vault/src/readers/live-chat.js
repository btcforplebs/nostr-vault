// A live stream's chat and sharing, as the iPhone has them since #1306 (LiveChat, LiveChatMedia, LiveStreamShare),
// with Tron's must-fixes from that review:
// - every chat event's own signature is checked, and it must carry this stream's exact `a` tag;
// - a zap names its payer only when the zap request inside the receipt is signed by them AND was made for this stream
//   (its own `a` tag) AND the receipt comes from the payee's own zap service (their LNURL's nostrPubkey), else the row
//   says "Someone" and has no profile, Mute or Report;
// - one row per zap request: a real public request wrapped in any number of forged receipts is still one zap (Tron,
//   PR 1309: three forged 9735s around one "gm" request gave three rows at 10,000,000 sats each);
// - a message shows at most MAX_MEDIA pictures or videos, and any further links stay as text.
import { verifyEvent } from "nostr-tools/pure"
import { naddrEncode, npubEncode } from "nostr-tools/nip19"
import { zapSats } from "../net/notifications.js"
import { mediaType } from "../net/media.js"
import { CHAT_KIND, LIVE_KIND, STREAM_RELAY } from "./live.js"

export const MAX_MEDIA = 4
export const SITE = "https://nostrvault.app"
const HEX64 = /^[0-9a-f]{64}$/

/** verifyEvent on a fresh copy of the signed fields: it trusts a "verified" mark an object may already carry. */
export function signed(ev) {
  if (!ev || typeof ev !== "object") return false
  const { id, pubkey, created_at, kind, tags, content, sig } = ev
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}

const forStream = (tags, address) => Array.isArray(tags) && tags.some(t => Array.isArray(t) && t[0] === "a" && t[1] === address)

/**
 * The zap request inside a receipt, when it names who paid: signed by them, and made for this stream. -> request | null.
 * Every request is public, so one made for another note can be wrapped in a fresh receipt for this stream; and the
 * receipt's own pubkey and `P` tag are whatever its signer wrote.
 */
export function payerRequest(receipt, address) {
  const d = (receipt.tags ?? []).find(t => t[0] === "description")?.[1]
  if (typeof d !== "string") return null
  let req
  try { req = JSON.parse(d) } catch { return null }
  if (req?.kind !== 9734 || !HEX64.test(req.pubkey ?? "") || !forStream(req.tags, address) || !signed(req)) return null
  return req
}

/** The zap request a receipt carries, parsed but not trusted, or null. */
const requestIn = receipt => { try { const r = JSON.parse((receipt.tags ?? []).find(t => t[0] === "description")?.[1] ?? ""); return r && typeof r === "object" ? r : null } catch { return null } }
const payeeOf = ev => (ev.tags ?? []).find(t => t[0] === "p" && HEX64.test(t[1] ?? ""))?.[1] ?? null

/**
 * A chat row from a relay event, or null when it doesn't belong: unsigned or mis-signed, not tagged with this
 * stream's address, or not a message or zap. `publishers` maps a payee to their zap service's pubkey (zaps.js
 * zapPublisherOf), null when it didn't resolve: a zap names its payer only from a receipt that service published.
 * -> { id, who: pubkey | null, at, text, sats, zap, request: id | null, event }
 */
export function chatRow(ev, address, publishers = new Map()) {
  if (!ev?.id || !forStream(ev.tags, address) || !signed(ev)) return null
  if (ev.kind === CHAT_KIND) {
    const text = String(ev.content ?? "").trim()
    return text ? { id: ev.id, who: ev.pubkey, at: ev.created_at, text, sats: 0, zap: false, request: null, event: ev } : null
  }
  if (ev.kind !== 9735) return null
  const raw = requestIn(ev)
  const publisher = publishers.get(payeeOf(ev))
  const req = publisher && publisher === ev.pubkey ? payerRequest(ev, address) : null
  return { id: ev.id, who: req?.pubkey ?? null, at: ev.created_at, text: String(raw?.content ?? "").trim(), sats: zapSats(ev), zap: true,
    request: typeof raw?.id === "string" ? raw.id : null, event: ev }
}

/** Rows oldest first, once each (a zap once per zap request), blocked and muted people left out, the newest `max`
 *  kept. A zap naming nobody is never hidden as anyone's. Of several receipts for one request, the one that names its
 *  payer is kept, else the earliest. */
export function chatRows(evs, address, hidden = new Set(), max = 200, publishers = new Map()) {
  const by = new Map()
  const rows = evs.map(ev => chatRow(ev, address, publishers)).filter(Boolean).sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1))
  for (const r of rows) {
    const key = r.request ? `req:${r.request}` : r.id
    const have = by.get(key)
    if (!have || (!have.who && r.who)) by.set(key, r)
  }
  // Muted people leave after the dedupe, so a forged copy of a muted payer's request can't stand in as Someone.
  return [...by.values()].filter(r => !(r.who && hidden.has(r.who))).sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1)).slice(-max)
}

/** A link the chat shows as a picture, GIF or video. */
export const mediaUrl = word => (/^https?:\/\/\S+$/.test(word) && mediaType(word) ? word : null)

/** A message's text and its media links, in the order written, once each, MAX_MEDIA at most: the rest stay in the
 *  text. Each line is split on its own, so a link on its own line doesn't glue the words around it. -> { text, media } */
export function splitMedia(text) {
  const media = []
  const lines = String(text ?? "").split("\n").map(line => line.split(" ").filter(w => {
    const url = mediaUrl(w.trim())
    if (!url) return true
    if (media.includes(url)) return false
    if (media.length >= MAX_MEDIA) return true
    media.push(url)
    return false
  }).join(" ").trim())
  return { text: lines.join("\n").trim(), media }
}

/** The kind 1311 a chat message is sent as (LiveChatService.send). */
export const chatTemplate = (address, text, now = Math.floor(Date.now() / 1000)) =>
  ({ kind: CHAT_KIND, created_at: now, tags: [["a", address, STREAM_RELAY]], content: String(text).trim() })

/** The stream's naddr, by whoever signed it (a service such as zap.stream signs for the host), with its relays as hints. */
export const streamNaddr = s => naddrEncode({ kind: LIVE_KIND, pubkey: s.author, identifier: s.identifier, relays: s.chatRelays.filter(r => /^wss?:\/\//.test(r)).slice(0, 2) })

/** nostrvault.app/thread/<naddr>: the public post page reads an naddr as well as a nevent. */
export const streamShareLink = s => `${SITE}/thread/${streamNaddr(s)}`

/** The host's public profile page. */
export const profileShareLink = pubkey => `${SITE}/p/${npubEncode(pubkey)}`

/** "Share as a note" (LiveStreamShare.noteText): a heading, then one link per line (the picture, the playlist,
 *  nostr:naddr) so other apps draw each one. */
export function noteText({ title, hostName, picture, streaming, naddr }) {
  const heading = title?.trim() ? `${title.trim()}, live now with ${hostName}` : `${hostName} is live now`
  const links = [picture, streaming, naddr && `nostr:${naddr}`].filter(Boolean)
  return links.length ? [heading, "", ...links].join("\n") : heading
}

/** What a chat row offers (LiveChatRowView / chatRowMenu): a row naming nobody (a zap whose payer is unproven) says
 *  "Someone" and offers nothing; else a profile link, Mute (not yourself, not read-only), Report (not read-only).
 *  -> { label, profile: "#/profile/<pk>" | null, mute, report } */
export function rowOffers(row, me, readOnly = false) {
  if (!row?.who) return { label: "Someone", profile: null, mute: false, report: false }
  return { label: null, profile: `#/profile/${row.who}`, mute: !readOnly && row.who !== me, report: !readOnly }
}
