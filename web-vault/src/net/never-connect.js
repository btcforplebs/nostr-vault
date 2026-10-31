// The user's Never Connect list (kind 10006, NIP-51), as the iPhone keeps it (RelayBlocklist): the pool refuses to open
// a socket to anything on it. A relay with no path blocks every path on that host and port (wss://relay.example also
// covers wss://relay.example/inbox, not wss://relay.example:8443). Relays that aren't public (loopback, LAN, .onion,
// .local, plain ws://) are never blocked: the user's own vault relay lives there (RelayMatrix.isPublicRelay).
// Kept per account in this browser too, so it holds from the first socket of the next visit, before Haven is up.

const KEY = "nv-never-connect"

const parse = url => {
  try {
    const u = new URL(String(url).trim())
    if (u.protocol !== "wss:" && u.protocol !== "ws:") return null
    const host = u.hostname.toLowerCase(), port = u.port, path = u.pathname.replace(/\/+$/, "")
    return { scheme: u.protocol, host, authority: port ? `${host}:${port}` : host, key: `${u.protocol}//${port ? `${host}:${port}` : host}${path}`, path }
  } catch { return null }
}

/** The iPhone's RelayMatrix.isPublicRelay: wss, a dotted host, not loopback, LAN, link-local, .onion or .local. */
export function isPublicRelay(url) {
  const p = parse(url)
  if (!p || p.scheme !== "wss:" || !p.host.includes(".")) return false
  const h = p.host
  if (h === "localhost" || h.endsWith(".onion") || h.endsWith(".local")) return false
  if (["127.", "10.", "192.168.", "0.", "169.254."].some(x => h.startsWith(x))) return false
  const m = /^172\.(\d+)\./.exec(h)
  return !(m && +m[1] >= 16 && +m[1] <= 31)
}

/** A matcher for `urls`: -> url => whether it is blocked. */
export function blocklist(urls = []) {
  const keys = new Set(), authorities = new Set()
  for (const u of urls) {
    const p = parse(u)
    if (!p || !isPublicRelay(u)) continue
    keys.add(p.key)
    if (!p.path) authorities.add(`${p.scheme}${p.authority}`)
  }
  const blocked = url => {
    const p = parse(url)
    return !!p && (keys.has(p.key) || authorities.has(`${p.scheme}${p.authority}`))
  }
  blocked.size = keys.size
  return blocked
}

/** The list's relays from a kind 10006's `relay` tags. */
export const neverConnectUrls = ev => (ev?.tags ?? []).filter(t => t[0] === "relay" && /^wss?:\/\//i.test(t[1] ?? "")).map(t => t[1].trim())

export function readKept(pubkey, storage = globalThis.localStorage) {
  try { const v = JSON.parse(storage?.getItem(`${KEY}:${pubkey}`) ?? "[]"); return Array.isArray(v) ? v.filter(u => typeof u === "string") : [] } catch { return [] }
}
export function keep(pubkey, urls, storage = globalThis.localStorage) {
  if (!pubkey) return
  try { urls.length ? storage?.setItem(`${KEY}:${pubkey}`, JSON.stringify(urls)) : storage?.removeItem(`${KEY}:${pubkey}`) } catch {}
}
