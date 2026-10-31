// Where a sign-in looks for the account's own old posts (Logen 2026-10-31, as iOS and Android setup import): the
// relays the account published as its own (kind 10002, write or unmarked), on top of the apps' five and the Mac vault.
// Read only: nothing here publishes or changes their list. Their relays are kept only when public (wss, a dotted host,
// not loopback, LAN, link-local, .local or .onion: never-connect.js isPublicRelay); the Mac vault (a loopback relay) is
// kept only on a page open on that same machine, the only browser that can reach it. Each relay once, however it was
// written (case, trailing slash).
import { DEFAULT_RELAYS, isDead, isLoopback } from "./pool.js"
import { isPublicRelay } from "./never-connect.js"

/** A relay URL in one spelling (lower-case scheme and host, no trailing slash), or null when it isn't a ws(s) URL. */
export function relayKey(url) {
  try {
    const u = new URL(String(url).trim())
    if (u.protocol !== "wss:" && u.protocol !== "ws:") return null
    return `${u.protocol}//${u.host.toLowerCase()}${u.pathname.replace(/\/+$/, "")}${u.search}`
  } catch { return null }
}

const pageIsLocal = host => isLoopback(`ws://${host || "x.invalid"}`)

/**
 * `account.relays.write` (their 10002's write and unmarked relays, net/pool.js relayLists) that are public, then the
 * apps' five, then a loopback relay of theirs when this page is on that machine. -> [url], once each.
 */
export function ownPostRelays(account, pageHost = globalThis.location?.hostname ?? "") {
  const theirs = account?.relays?.write ?? []
  const out = new Map()
  const add = url => { const k = relayKey(url); if (k && !isDead(k) && !out.has(k)) out.set(k, k) }
  for (const url of theirs) if (isPublicRelay(url)) add(url)
  for (const url of DEFAULT_RELAYS) add(url)
  if (pageIsLocal(pageHost)) for (const url of theirs) if (isLoopback(url)) add(url)
  return [...out.values()]
}
