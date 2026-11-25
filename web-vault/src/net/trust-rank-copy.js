// A desktop Vault's trust rank for one account, as the web keeps it: the web twin of Apple Models/TrustRankCopy.swift
// and Android data/model/TrustRankCopy.kt. The file is the engine's `wot_rank_<account>.json` (haven-go
// copyv2_trust.go, docs/MESH_COPY_V2_CONTRACT.md §6.5). The globe reads only `globe` (each far ring's top, best first,
// with the `via` that links them one ring in) and `haze` (rings 3 and 4, the people ranked after that top). `people`
// is the feed's and is read here only so that a file the apps refuse is refused here too.
//
// Pure: parse(text or object, account) is the copy or null. The checks are the engine's own (trustrank.CheckHandoff),
// made again because a file is only as good as whoever wrote it last. One difference from Swift: JSON.parse reads
// `2.0` as the whole number 2, which Swift refuses. The engine never writes one.

/** trustrank.CeilingHop: the furthest ring a rank reaches. */
export const CEILING_HOP = 6
/** trustrank.GlobeHop: the furthest ring the globe list covers. */
export const GLOBE_HOP = 5
/** trustrank.GlobePerRing: each ring's top, best first. */
export const GLOBE_PER_RING = 300
/** At most this many globe rows (contract §6.5: 9 × 300, chain links need links of their own). */
export const MAX_GLOBE_ROWS = 9 * GLOBE_PER_RING
/** trustrank.HazePerRing: the most haze rows a ring carries (1,000 and 2,000 people in all, less the ring's top). */
export const HAZE_PER_RING = { 3: 700, 4: 1700 }

const HEX64 = /^[0-9a-f]{64}$/
const isNumber = v => typeof v === "number" && Number.isFinite(v)
const isWhole = v => isNumber(v) && Number.isInteger(v)
/** A number on the 0-100 shown scale; anything else is as if missing (Tron, #2427). */
const onScale = v => (isNumber(v) && v >= 0 && v <= 100 ? v : null)

/** haven-go trustrank.ResultPath. */
export const fileName = account => `wot_rank_${account}.json`

/**
 * The copy, when it is `account`'s, version 2, and every row passes the engine's checks; anything else is null.
 * -> { account, builtAt, maxHop, viewBar, floor, people: Map(pk -> { score, hop }), globeOrder: [pk],
 *      globe: Map(pk -> { score, hop, via }), haze: Map(hop -> [pk]) }
 */
export function parse(input, account) {
  let root = input
  if (typeof input === "string") { try { root = JSON.parse(input) } catch { return null } }
  if (!root || typeof root !== "object" || Array.isArray(root)) return null
  if (root.account !== account || root.version !== 2 || !isWhole(root.version)) return null
  const { builtAt, maxHop } = root
  if (!isWhole(builtAt) || builtAt <= 0 || !isWhole(maxHop) || maxHop < 1 || maxHop > CEILING_HOP) return null
  if (!Array.isArray(root.people)) return null
  const people = new Map()
  for (const row of root.people) {
    if (!Array.isArray(row) || row.length !== 3) return null
    const [pk, score, hop] = row
    if (typeof pk !== "string" || !HEX64.test(pk) || !isNumber(score) || score < 0 || score > 100) return null
    if (!isWhole(hop) || hop < 1 || hop > maxHop) return null
    people.set(pk, { score, hop })
  }
  const rows = parseGlobe(root.globe, maxHop)
  if (!rows) return null
  const globe = new Map(), globeOrder = []
  // A key twice keeps its first row (the engine never writes one twice).
  for (const [pk, person] of rows) if (!globe.has(pk)) { globe.set(pk, person); globeOrder.push(pk) }
  return {
    account, builtAt, maxHop,
    viewBar: onScale(root.viewBar) ?? 55, floor: onScale(root.floor) ?? 0,
    people, globeOrder, globe, haze: parseHaze(root.haze, maxHop, globe),
  }
}

/** The optional `globe` (trustrank.CheckHandoff): missing or null is empty; anything not a list of good rows is null. */
function parseGlobe(value, maxHop) {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value) || value.length > MAX_GLOBE_ROWS) return null
  const top = Math.max(2, Math.min(GLOBE_HOP, maxHop)), out = []
  for (const row of value) {
    if (!Array.isArray(row) || row.length !== 4) return null
    const [pk, score, hop, via] = row
    if (typeof pk !== "string" || !HEX64.test(pk) || !isNumber(score) || score < 0 || score > 100) return null
    if (!isWhole(hop) || hop < 2 || hop > top || hop > maxHop) return null
    if (typeof via !== "string" || !HEX64.test(via)) return null
    out.push([pk, { score, hop, via }])
  }
  return out
}

/**
 * The optional `haze` (haven-go checkHaze): rings "3" and "4" only (and up to maxHop), each within HAZE_PER_RING,
 * every row a hex pubkey shown over 0 and at most 100, in no other ring and not a globe row. A bad haze costs only the
 * haze: it is empty and the copy stays. -> Map(hop -> [pk, best first])
 */
export function parseHaze(value, maxHop, globe) {
  const out = new Map()
  if (!value || typeof value !== "object" || Array.isArray(value)) return out
  const seen = new Set()
  for (const [name, rows] of Object.entries(value)) {
    const hop = Number(name)
    const cap = HAZE_PER_RING[hop]
    if (!Number.isInteger(hop) || String(hop) !== name || !cap || hop > maxHop) return new Map()
    if (!Array.isArray(rows) || rows.length > cap) return new Map()
    const keys = []
    for (const row of rows) {
      if (!Array.isArray(row) || row.length !== 2) return new Map()
      const [pk, score] = row
      if (typeof pk !== "string" || !HEX64.test(pk) || !isNumber(score) || score <= 0 || score > 100) return new Map()
      if (globe.has(pk) || seen.has(pk)) return new Map()
      seen.add(pk)
      keys.push(pk)
    }
    out.set(hop, keys)
  }
  return out
}

/** A globe row, for the globe and the chain only. */
export const globePerson = (copy, pubkey) => copy?.globe.get(String(pubkey ?? "").toLowerCase()) ?? null
