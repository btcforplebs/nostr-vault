// The layer picker's Hop 3, 4 and 5: always in the list, greyed out until a desktop Vault's rank with that ring is in
// this browser (trust-map-outer.js unlocks), as the reason to run one. A greyed hop says so in one line; an unlocked one
// zooms your globe out to its ring (globe-ring-zoom.js). The web twin of Apple TrustWebView+HopLayers.swift and
// TrustMap.Layer's hop cases. Pure.
import { unlocks, ringOf, shownCount, LOCKED_LINE } from "./trust-map-outer.js"

/** [id, title, hop], after wot.js LAYERS in the picker. */
export const HOP_LAYERS = [["hop3", "Hop 3", 3], ["hop4", "Hop 4", 4], ["hop5", "Hop 5", 5]]
export { LOCKED_LINE }

/** The hop a layer id picks, or null for your circle's layers. */
export const hopOf = id => HOP_LAYERS.find(([k]) => k === id)?.[2] ?? null

/** What the inner globe lights: a hop shows Everyone, shrunk (TrustMap.Layer.globeLayer). */
export const globeLayerOf = id => (hopOf(id) == null ? id : "everyone")

/** The hop layer is greyed out: no ranked ring for it here yet. Your circle's layers never are. */
export const isLocked = (outer, id) => { const hop = hopOf(id); return hop != null && !unlocks(outer, hop) }

/** Each unlocked hop's count: everyone its sphere draws (top plus haze), or null (no number) when there is no haze,
 *  since then the ring is only its top 300, a cap rather than a count (Logen 2026-11-25). Locked hops are null too. */
export function hopCounts(outer) {
  const out = {}
  for (const [id, , hop] of HOP_LAYERS) out[id] = isLocked(outer, id) ? null : shownCount(ringOf(outer, hop))
  return out
}
