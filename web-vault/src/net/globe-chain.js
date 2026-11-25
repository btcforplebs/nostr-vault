// The path from someone on a hop sphere back to you (Logen 2026-11-25): their `via` in the rank copy's globe list, that
// person's `via`, and so on in toward your follows, each with the ring they sit on. The globe draws a line through each
// one's spot on its layer to you in the middle (screens/globe-chain-painter.js); a link not on screen is skipped. The
// web twin of Apple Models/GlobeChain.swift (PR 2526). Pure.
import { globePerson, CEILING_HOP } from "./trust-rank-copy.js"

/** `key` first, then each `via` in, ending at one of your follows (hop 1) or wherever the copy stops knowing. Never
 *  loops, never longer than the rings there are. -> [{ key, hop }] (hop null when unknown), [] when `key` has no row. */
export function chainLinks(key, copy, follows) {
  const first = globePerson(copy, key)
  if (!first) return []
  const out = [{ key, hop: first.hop }], seen = new Set([key])
  let via = first.via
  while (via && !seen.has(via) && out.length <= CEILING_HOP) {
    seen.add(via)
    if (follows.has(via)) { out.push({ key: via, hop: 1 }); break }
    const person = globePerson(copy, via)
    out.push({ key: via, hop: person?.hop ?? null })
    via = person?.via ?? ""
  }
  return out
}
