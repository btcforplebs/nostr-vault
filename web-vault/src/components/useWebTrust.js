import { useEffect, useState } from "preact/hooks"
import { trustSet } from "../net/popular.js"
import { insideWeb } from "../net/web-trust.js"

// The web of trust for what other people send (net/web-trust.js): one set per account and follow list, shared by
// every screen that asks (the follows' contact lists are cached by wot.js followLists). Null until it is in; a failed
// load stays null, so the screens keep showing only you and your follows rather than everyone.
let latest = { key: "", trust: null }
let loading = null
const listeners = new Set()

export function useWebTrust(ctx) {
  const me = ctx?.session?.pubkey ?? null
  const follows = ctx?.account?.follows ?? []
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows[follows.length - 1] ?? ""}`
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick(t => t + 1)
    listeners.add(bump)
    return () => listeners.delete(bump)
  }, [])
  useEffect(() => {
    if (!me || latest.key === key || loading?.key === key) return
    const run = { key }
    loading = run
    trustSet(me, follows).then(trust => {
      if (loading !== run) return
      latest = { key, trust }
      for (const cb of listeners) cb()
    }).catch(() => {}).finally(() => { if (loading === run) loading = null })
  }, [key])
  const trust = latest.key === key ? latest.trust : null
  return { trust, inside: (pk, also = []) => insideWeb(pk, trust, { me, follows, also }) }
}
