// The Web of Trust's pure pieces, with no imports: a person's spot from their key (fraction), the trust path a card
// shows, the layer picker. net/wot.js re-exports them, and the WoT napplet (napplets/wot, plan P6) carries this file
// as it is (src/napplet/wot-inject.js), so the globe in the napplet and in the app read people the same way.
/** Bridges a card names and shows; more than this reads "+ more" (TrustPath.shownBridges). */
export const SHOWN_BRIDGES = 5

/**
 * How someone reaches you, as the iPhone's TrustPath: { reach, bridges, hasMore, all }. `reach` is "you", "follow"
 * (1 hop), "bridged" (someone you follow follows them: 2 hops) or "outside". `all` is every follow of yours who
 * follows them, sorted by key as the phone sorts them; `bridges` is its first SHOWN_BRIDGES. The phone's "web" (in its
 * relay's graph with no bridge found) can't happen here: this web is made of bridges. null with no web yet.
 */
export function trustPath(web, pk) {
  if (!web) return null
  if (pk === web.me) return { reach: "you", bridges: [], hasMore: false, all: [] }
  const all = [...(web.linkers.get(pk) ?? [])].sort()
  const bridges = all.slice(0, SHOWN_BRIDGES)
  const reach = web.layerOf(pk) === "follow" ? "follow" : bridges.length ? "bridged" : "outside"
  return { reach, bridges, hasMore: all.length > SHOWN_BRIDGES, all }
}

/**
 * The trust card's one line, word for word the iPhone's (TrustPathText.label): "You follow them · 1 hop",
 * "You follow them · also followed by Ann and Bob", "Followed by Ann, Bob + more you follow · 2 hops",
 * "Not in your web · no one you follow follows them". `name(pk)` gives a display name.
 */
export function trustPathText(web, pk, name) {
  const path = trustPath(web, pk)
  if (!path) return "Tracing how they reach you…"
  switch (path.reach) {
    case "you": return "This is you."
    case "follow": return path.bridges.length ? `You follow them · also followed by ${bridgeNames(path, name)}` : "You follow them · 1 hop"
    case "bridged": return `Followed by ${bridgeNames(path, name)} you follow · 2 hops`
    default: return "Not in your web · no one you follow follows them"
  }
}

function bridgeNames(path, name) {
  const names = path.bridges.slice(0, 2).map(name)
  return path.bridges.length > names.length || path.hasMore ? `${names.join(", ")} + more` : names.join(" and ")
}

/** The WoT tab's layer picker, the iPhone's names (TrustMap.Layer): [id, title, the web's layer it shows]. */
export const LAYERS = [["everyone", "Everyone", null], ["following", "Following", "follow"], ["close", "Vouched", "extended"], ["furtherOut", "Further out", "further"]]

/** People in each layer, never counting you (TrustMap.layerCounts): { everyone, following, close, furtherOut }. */
export function layerCounts(web) {
  const following = web.follows.length, close = web.extended.length, furtherOut = web.further.length
  return { everyone: following + close + furtherOut, following, close, furtherOut }
}

/**
 * A number from 0 to 1 from a pubkey's characters at `offset` on, as the iPhone's TrustMap.fraction does it, so a
 * person sits in the same place on the web as on the phone: the 8 characters there read as a hex number
 * (`UInt32(hex, radix: 16)`, which also takes a leading "+", and a "-" when the value is 0), or, when they aren't hex
 * (only for malformed keys), FNV-1a over the UTF-8 bytes from byte `offset` on. Test fixtures come from the Swift
 * function itself, compiled from TrustMap.swift.
 */
export function fraction(pubkey, offset) {
  const v = hexPrefix(Array.from(pubkey).slice(offset, offset + 8).join(""))
  if (v !== null) return v / 4_294_967_296
  let hash = 2_166_136_261
  const bytes = utf8.encode(pubkey)
  for (let i = offset; i < bytes.length; i++) hash = Math.imul(hash ^ bytes[i], 16_777_619) >>> 0
  return hash / 4_294_967_296
}
const utf8 = new TextEncoder()

/** Swift's UInt32(s, radix: 16) for an 8-character string: the value, or null where Swift gives nil. */
export function hexPrefix(s) {
  if (Array.from(s).length !== 8) return null
  const m = /^([+-]?)([0-9a-fA-F]+)$/.exec(s)
  if (!m) return null
  const v = parseInt(m[2], 16)
  return m[1] === "-" && v !== 0 ? null : v
}
