// The Web of Trust mini panel's rules (no styles, so tests can import it). The panel shows a small slow globe of your
// web and who is new in it: people your follows have come to vouch for (the web's extended layer, wot.js EXTENDED_MIN
// or more of your follows follow them) since this browser last looked. A click on one opens their trust card in the
// left column (#/wot/<hex>, as a profile's Web of Trust button does).
import { direction, RADIUS } from "../../net/wot-globe.js"

/** Faces the panel shows in its "New in your web" row. */
export const NEW_FACES = 6
/** How long someone stays "new" after the browser first saw them in your web. */
export const NEW_FOR_S = 7 * 86400
/** Newcomers kept at most (newest first). */
export const NEW_KEPT = 40
/** Of your follows, the share whose lists may still be unsettled (on their way, or cut off and due again) for the web
 *  to count as mapped: a web built from part of the lists has people missing, who would come back later as "new".
 *  Lists a relay doesn't have (wot.js known misses) don't count: they won't come. */
export const MAPPED_SHARE = 0.02
/** Asks again for lists that were cut off at most this many times, RETRY_MS apart. */
export const MAP_ROUNDS = 3
/** Vouched people drawn on the little globe at most (the follows are all drawn). */
export const GLOBE_OUTER = 400

/** The first 8 hex characters of a key: enough to tell a few thousand people apart, a quarter of the room. */
const short = pk => pk.slice(0, 8)

/** Is the web built from enough of the follows' lists to say who is new? `unsettled`: wot.js unsettledLists. */
export const mapped = (follows, unsettled) => follows > 0 && unsettled <= Math.floor(follows * MAPPED_SHARE)

/** The panel's line while the web loads: "Loading your web: 640 of 1,054 follows' lists". */
export const loadingText = (have, follows) => `Loading your web: ${have.toLocaleString()} of ${follows.toLocaleString()} follows' lists`

/**
 * Who is new among `vouched` (the web's extended layer, most linked first), against what this browser kept `kept`
 * ({ known: Set of short keys, fresh: [[pk, first seen]] } or null on a first look) -> { fresh, kept }. Anyone in
 * `muted` (the block list, kind 10000) is never offered and never newly noted: the web build already leaves them out
 * (wot.js buildWeb), and the offer checks again, so a block list that landed after the web did can't flash someone
 * you muted. A first look only notes everyone: nothing is new yet. Later, anyone not seen before is new from `now`;
 * someone stays new for NEW_FOR_S while still vouched for. Known people are never forgotten, so someone a missing
 * list hides for a while doesn't come back as new.
 */
export function newInWeb(vouched, kept, now, muted = new Set()) {
  const clean = muted.size ? vouched.filter(pk => !muted.has(pk)) : vouched
  const known = new Set(kept?.known ?? [])
  if (!kept) {
    for (const pk of clean) known.add(short(pk))
    return { fresh: [], kept: { known, fresh: [] } }
  }
  const still = new Set(clean)
  const fresh = (kept.fresh ?? []).filter(([pk, at]) => still.has(pk) && now - at < NEW_FOR_S)
  const had = new Set(fresh.map(([pk]) => pk))
  const arrived = clean.filter(pk => !known.has(short(pk)) && !had.has(pk)).map(pk => [pk, now])
  for (const pk of clean) known.add(short(pk))
  const all = [...arrived, ...fresh].slice(0, NEW_KEPT)
  return { fresh: all.map(([pk]) => pk), kept: { known, fresh: all } }
}

// Kept per account in this browser. The key ends in ":<pubkey>", so signing out wipes it with the rest of the
// account's keys (haven/vault.js accountKeys).
const KEY = "nv-wot-seen"
const HEX64 = /^[0-9a-f]{64}$/
export function readKept(me, storage = globalThis.localStorage) {
  try {
    const raw = storage?.getItem(`${KEY}:${me}`)
    if (!raw) return null
    const { known, fresh } = JSON.parse(raw)
    if (typeof known !== "string" || !Array.isArray(fresh)) return null
    return {
      known: new Set(known.match(/[0-9a-f]{8}/g) ?? []),
      fresh: fresh.filter(e => Array.isArray(e) && HEX64.test(e[0]) && Number.isFinite(e[1])),
    }
  } catch { return null }
}
export function writeKept(me, { known, fresh }, storage = globalThis.localStorage) {
  try { storage?.setItem(`${KEY}:${me}`, JSON.stringify({ known: [...known].join(""), fresh })) } catch {}
}

/** "Followed by 12 of your follows" for a vouched person, from the web's linkers. */
export const vouchText = (web, pk) => {
  const n = web.linkers.get(pk)?.length ?? 0
  return `Followed by ${n.toLocaleString()} ${n === 1 ? "person" : "people"} you follow`
}

/**
 * The little globe's points: the follows on the inner shell and up to GLOBE_OUTER vouched people on the next, each where
 * the big globe puts them (wot-globe.js direction), and the new people marked. -> [{ p: [x, y, z], kind }]
 * kind: "follow" | "vouched" | "new".
 */
export function globePoints(web, fresh = []) {
  const isNew = new Set(fresh)
  const outer = web.extended.slice(0, GLOBE_OUTER)
  for (const pk of fresh) if (!outer.includes(pk)) outer.push(pk)
  const at = (pk, r) => direction(pk).map(v => v * r)
  return [
    ...web.follows.map(pk => ({ p: at(pk, RADIUS.follow), kind: "follow" })),
    ...outer.map(pk => ({ p: at(pk, RADIUS.extended), kind: isNew.has(pk) ? "new" : "vouched" })),
  ]
}

/** A point turned `angle` round the upright axis and tipped `tilt` toward you, then flattened onto the panel:
 *  -> [x, y, depth], x and y in the globe's radii, depth -1 (back) to 1 (front) of the outer shell. */
export function turn([x, y, z], angle, tilt) {
  // The big globe's z is up; here y is down the screen.
  const c = Math.cos(angle), s = Math.sin(angle)
  const x1 = x * c - y * s, y1 = x * s + y * c
  const ct = Math.cos(tilt), st = Math.sin(tilt)
  const up = z * ct - y1 * st, depth = z * st + y1 * ct
  return [x1, -up, depth / RADIUS.extended]
}
