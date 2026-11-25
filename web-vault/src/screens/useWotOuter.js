// The far rings for your own globe on the WoT tab (net/trust-map-outer.js): this browser's copy of a desktop Vault's
// rank for the account (net/rank-copy-store.js), whether a desktop Vault is paired here (net/pair-devices.js), less your
// blocks. Re-read when a copy arrives. The web twin of Apple's TrustMapOuterWatch.
import { useEffect, useMemo, useState } from "preact/hooks"
import { rankCopyFor, onRankCopy } from "../net/rank-copy-store.js"
import { makeOuter, desktopPaired } from "../net/trust-map-outer.js"
import { pairedDevices } from "../net/pair-devices.js"

const pairedHere = me => { try { return desktopPaired(pairedDevices(globalThis.localStorage, me)) } catch { return false } }

/** -> the outer rings for `me`, or the invite rings while nothing is known. `blocked`: a Set of hex keys. */
export function useWotOuter(me, blocked) {
  const [round, bump] = useState(0)
  useEffect(() => onRankCopy(account => { if (account === me) bump(n => n + 1) }), [me])
  return useMemo(() => makeOuter(rankCopyFor(me), pairedHere(me), blocked ?? new Set()), [me, blocked, round])
}
