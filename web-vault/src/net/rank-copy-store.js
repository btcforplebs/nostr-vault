// This browser's copy of a desktop Vault's trust rank, one per account (net/trust-rank-copy.js): the web twin of Apple
// Services/TrustRankCopyStore.swift. Kept in memory with the page. Nothing fills it in a real build yet: the way the
// web will fetch it (a mesh-key read from the paired desktop Vault) waits on the door route (docs, PR 1 of the web hop
// sphere plan). Until then the globe's far rings read "waiting" or "invite", and Hop 3/4/5 stay greyed.
//
// A test build (NV_RANK_FIXTURES=1, vite.config.js) adds `globalThis.__nvSetRankCopy(account, json)`, so a headless
// check can hand the globe a copy. A real build leaves that code out (__NV_RANK_FIXTURES__ is false).
import { parse } from "./trust-rank-copy.js"

const copies = new Map() // account hex -> copy
const listeners = new Set()

/** The copy for `account`, or null. */
export const rankCopyFor = account => copies.get(String(account ?? "").toLowerCase()) ?? null

/** Keeps `input` (file text or object) as `account`'s copy when it parses; a copy that doesn't is refused and the last
 *  good one stays, as on the apps. null clears it (signed out, unpaired). -> true when kept or cleared */
export function setRankCopy(account, input) {
  const key = String(account ?? "").toLowerCase()
  if (input === null) {
    if (!copies.delete(key)) return true
  } else {
    const copy = parse(input, key)
    if (!copy) return false
    copies.set(key, copy)
  }
  for (const f of listeners) f(key)
  return true
}

/** Calls `f(account)` on every change. -> unsubscribe */
export function onRankCopy(f) {
  listeners.add(f)
  return () => listeners.delete(f)
}

const fixtures = typeof __NV_RANK_FIXTURES__ !== "undefined" && __NV_RANK_FIXTURES__ === true
if (fixtures) globalThis.__nvSetRankCopy = setRankCopy
