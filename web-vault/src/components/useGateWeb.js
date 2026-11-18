import { useEffect, useMemo, useState } from "preact/hooks"
import { followLists } from "../net/wot.js"
import { webLayers, gateWeb } from "../net/web-gate.js"
import { loadAccounts } from "../session.js"

// The open account's web as the one gate reads it (net/web-gate.js), shared by every screen that asks. The layers
// (web and hop 3, from the follows' contact lists, which wot.js followLists caches) are built once per account and
// follow list; blocks are laid on top each time they change. Until the lists are in, and if they never come, the web
// is the account's own keys and follows (fail closed): a stranger never shows and then goes.
let latest = { key: "", layers: null }
let loading = null
const listeners = new Set()

const ownKeys = me => {
  let keys = []
  try { keys = loadAccounts().map(a => a.pubkey) } catch {}
  return [me, ...keys].filter(Boolean)
}

export function useGateWeb(ctx, blocked) {
  const me = ctx?.session?.pubkey ?? null
  const follows = ctx?.account?.follows ?? []
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows[follows.length - 1] ?? ""}:${blocked?.size ?? 0}`
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick(t => t + 1)
    listeners.add(bump)
    return () => listeners.delete(bump)
  }, [])
  useEffect(() => {
    if (!me || !follows.length || latest.key === key || loading?.key === key) return
    const run = { key }
    loading = run
    followLists(me, follows).then(lists => {
      if (loading !== run) return
      latest = { key, layers: webLayers({ follows, lists, own: ownKeys(me), blocked }) }
      for (const cb of listeners) cb()
    }).catch(() => {}).finally(() => { if (loading === run) loading = null })
  }, [key])
  // While a new follow list or block list rebuilds the layers, the account's last ones stand rather than the narrow
  // follows-only web, so the feed doesn't fold and unfold around a block.
  const layers = latest.key === key || latest.key.startsWith(`${me}:`) ? latest.layers : null
  return useMemo(() => gateWeb({
    own: ownKeys(me),
    web: layers?.web ?? follows,
    hop3: layers?.hop3 ?? [],
    blocked,
  }), [me, layers, blocked, key])
}
