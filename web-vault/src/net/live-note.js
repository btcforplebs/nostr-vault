// A note that embeds a live stream (nostr:naddr of a kind 30311): the stream's card is the whole post. "Share as a
// note" used to write the cover picture and the .m3u8 playlist beside the naddr, so the note drew the card, the same
// picture again, a "livepeercdn.studio" link and blank lines. Here those links leave the text and the space around
// the card goes, which also cleans up notes already posted that way. Same rule on iOS and Android.
import { parseRef } from "./quotes.js"

const LIVE_KIND = 30311
const URL_TAGS = new Set(["streaming", "recording", "image", "thumb"])

/** The live streams a note's text embeds: [{ ref, key, pubkey, d, relays }], once each. */
export function liveRefs(content) {
  const out = []
  for (const m of String(content ?? "").matchAll(/nostr:(naddr1[a-z0-9]+)/gi)) {
    const q = parseRef(m[1].toLowerCase())
    if (q?.type !== "addr" || q.kind !== LIVE_KIND) continue
    const key = `${q.kind}:${q.pubkey}:${q.d}`
    if (!out.some(r => r.key === key)) out.push({ ref: m[1], key, pubkey: q.pubkey, d: q.d, relays: q.relays })
  }
  return out
}

/** The NIP-18 q tags for the live streams in a note: ["q", "30311:<pubkey>:<d>", <relay hint or "">]. */
export const liveQuoteTags = content => liveRefs(content).map(r => ["q", r.key, r.relays[0] ?? ""])

const isPlaylist = url => { try { return new URL(url).pathname.toLowerCase().endsWith(".m3u8") } catch { return false } }

/** The links to take out of a note's text: none unless it embeds a live stream; then any .m3u8 playlist (a stream
 *  link beside the stream's own card), and the streaming / recording / image / thumb links of each embedded stream
 *  whose event is known (`streams`: its kind 30311 events, or nulls while loading). */
export function liveDrops(links, hasLive, streams = []) {
  if (!hasLive) return new Set()
  const own = new Set()
  for (const ev of streams) for (const t of ev?.tags ?? []) if (URL_TAGS.has(t[0]) && t[1]) own.add(t[1])
  return new Set(links.filter(u => isPlaylist(u) || own.has(u)))
}

/** [text, token, text, …]: the whitespace either side of each live card (`isLive(token)`) taken out, so the card stands
 *  on its own and the heading above it doesn't end in blank lines. */
export function trimAroundLive(parts, isLive) {
  const out = parts.slice()
  for (let i = 1; i < out.length; i += 2) {
    if (!isLive(out[i])) continue
    out[i - 1] = out[i - 1].trimEnd()
    out[i + 1] = out[i + 1].trimStart()
  }
  return out
}
