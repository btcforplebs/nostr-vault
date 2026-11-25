// The globe's far rings: people three or more hops out, as a desktop Vault ranked them (net/trust-rank-copy.js), one
// ring per hop. The web twin of Apple Models/TrustMapOuter.swift and Android data/model/TrustMapOuter.kt.
//   ranked:  a rank copy is here. Each ring's top 300 from the copy's globe list, whatever their score (no bar: the
//            feed keeps the bar), with each one's `via` one ring in and the ring's haze.
//   waiting: a desktop Vault is paired but no rank has come yet. Faint rings, no people.
//   invite:  no desktop Vault. Faint rings.
// Pure, so test/trust-map-outer.test.mjs pins it.
import { GLOBE_HOP, GLOBE_PER_RING } from "./trust-rank-copy.js"

/** The first far ring: past your circle (follows, then the people they follow). */
export const FIRST_HOP = 3
/** Faint rings drawn with no rank: hops 3 to 5. */
export const FAINT_HOPS = [3, 4, 5]
/** How many people a ring's top holds: the engine's per-ring top. */
export const SHOWN_PEOPLE = GLOBE_PER_RING

export const LOCKED_LINE = "A desktop Vault unlocks the far rings"
export const FOUND_LABEL = "Found by your desktop Vault"
export const WAITING_LABEL = "Your desktop Vault hasn't sent its ranking yet"
export const PAIR_LINE = "Pair a desktop Vault to see distant connections"

const ring = (hop, top = [], via = new Map(), haze = []) => ({ hop, top, via, haze })

/** No rank and no desktop Vault. */
export const NONE = { source: "invite", rings: [] }

/**
 * -> { source: "ranked" | "waiting" | "invite", rings: [{ hop, top: [pk], via: Map(pk -> pk), haze: [pk] }] }, inner
 * to outer. `hidden`: people to leave out (your blocks).
 */
export function makeOuter(copy, desktopPaired, hidden = new Set()) {
  if (!copy) return { source: desktopPaired ? "waiting" : "invite", rings: FAINT_HOPS.map(hop => ring(hop)) }
  // The globe list's first SHOWN_PEOPLE rows of a hop are that ring's top, best first; any later ones are chain links
  // (contract §6.5). The top leaves out anyone who shows 0 (haven-go Globe), so a 0 row is always a link.
  const top = new Map(), via = new Map(), seen = new Map()
  for (const key of copy.globeOrder) {
    const person = copy.globe.get(key)
    if (!person || person.hop < FIRST_HOP || person.hop > GLOBE_HOP || !(person.score > 0)) continue
    const n = seen.get(person.hop) ?? 0
    if (n >= SHOWN_PEOPLE) continue
    seen.set(person.hop, n + 1)
    if (hidden.has(key)) continue
    if (!top.has(person.hop)) { top.set(person.hop, []); via.set(person.hop, new Map()) }
    top.get(person.hop).push(key)
    if (person.via && !hidden.has(person.via)) via.get(person.hop).set(key, person.via)
  }
  const rings = [...top.keys()].sort((a, b) => a - b).map(hop => {
    const mine = new Set(top.get(hop))
    const haze = (copy.haze.get(hop) ?? []).filter(pk => !hidden.has(pk) && !mine.has(pk))
    return ring(hop, top.get(hop), via.get(hop), haze)
  })
  return { source: "ranked", rings }
}

export const isFaint = outer => outer.source !== "ranked"

/** A hop layer (Hop 3, 4, 5) can be picked only once a desktop Vault's rank is here with that ring in it; until then
 *  the picker greys it out, as the reason to run one (Logen 2026-11-24). */
export const unlocks = (outer, hop) => outer.source === "ranked" && outer.rings.some(r => r.hop === hop)

/** The ring for `hop`, or null. */
export const ringOf = (outer, hop) => outer.rings.find(r => r.hop === hop) ?? null

/** How many people a hop's sphere draws: its top and its haze. null while there is no haze for it: then the ring is
 *  only its top 300, a cap rather than a count, so the picker shows no number (Logen 2026-11-25). */
export const shownCount = r => (r && r.haze.length ? r.top.length + r.haze.length : null)

/** How strong a ring's dots are: hop 3 full, hop 4 about 60%, hop 5 about 35%. */
export const fade = hop => (hop <= 3 ? 1 : hop === 4 ? 0.6 : 0.35)

/** A desktop Vault is among this browser's paired devices: a Mac, or a box (which pairs as one). */
export const desktopPaired = devices => (devices ?? []).some(d => d?.role === "mac")

/** "3 hops": the rank copy has no ring total, and the globe has no bar. */
export const chipText = r => `${r.hop} hops`

/** The sheet's line for a ring's top. */
export const countText = r => `The ${r.top.length.toLocaleString("en-US")} best-scored ${r.top.length === 1 ? "person" : "people"} in this ring, whatever their score.`
