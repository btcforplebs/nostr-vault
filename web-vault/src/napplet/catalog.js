// The Apps pane's catalog and installed list (plan P3). Pure: no DOM, no network (the pane hands in the pool query,
// the Blossom fetcher and its own storage), so node tests load it.
//
// The catalog is every addressable napplet manifest (kind 35129) the user's relays hold, newest per (publisher, d),
// with blocked publishers dropped (the shell's block list, decision 6). Installing one keeps its manifest event and
// its bytes; the bytes must hash to the manifest's `x` before they are kept or run. Its grant lives where every grant
// does (policy.js grantStore): the Apps pane only lets the user look at it, change it or take it away.
import { parseManifest, domainsFor, nappletKey, nappletLine } from "./manifest.js"

export const CATALOG_KIND = 35129
export const CATALOG_LIMIT = 300
/** A napplet is one small index.html. */
export const MAX_ARTIFACT = 5 * 1024 * 1024
export const catalogFilter = () => ({ kinds: [CATALOG_KIND], limit: CATALOG_LIMIT })

const tag = (ev, name) => (ev.tags ?? []).find(t => Array.isArray(t) && t[0] === name && typeof t[1] === "string")?.[1]

/**
 * Relay events -> catalog entries, newest first: { event, manifest, line, summary, picture, runs, why }.
 * `verify(ev)` checks the signature; `blocked` is a Set of pubkeys. `runs`: false (with `why`) when it needs a
 * domain this shell doesn't have; it is listed anyway, so the user sees why it can't be installed.
 */
export function catalogEntries(events, { verify = () => true, blocked = null } = {}) {
  const newest = new Map()
  for (const ev of events ?? []) {
    if (ev?.kind !== CATALOG_KIND || blocked?.has?.(ev.pubkey) || !verify(ev)) continue
    let manifest
    try { manifest = parseManifest(ev) } catch { continue }
    const line = nappletLine(manifest)
    const had = newest.get(line)
    if (had && (had.event.created_at > ev.created_at || (had.event.created_at === ev.created_at && had.event.id < ev.id))) continue
    newest.set(line, { event: ev, manifest })
  }
  return [...newest.values()].map(({ event, manifest }) => {
    let runs = true, why = ""
    try { domainsFor(manifest) } catch (e) { runs = false; why = String(e.message) }
    return {
      event, manifest, line: nappletLine(manifest), runs, why,
      summary: String(tag(event, "summary") ?? tag(event, "description") ?? event.content ?? "").slice(0, 280),
      picture: httpsOnly(tag(event, "icon") ?? tag(event, "image") ?? tag(event, "picture")),
    }
  }).sort((a, b) => b.event.created_at - a.event.created_at)
}

const httpsOnly = u => (typeof u === "string" && /^https:\/\//i.test(u) ? u : "")

/** Where a manifest's bytes may be: its `server` tags, then its publisher's media servers (kind 10063). The caller
 *  adds the usual servers and checks the hash (blossom-uri.js fetchVerified). */
export const manifestServers = ev => (ev.tags ?? []).filter(t => Array.isArray(t) && t[0] === "server" && typeof t[1] === "string").map(t => t[1])

/**
 * The manifest's artifact as text, hash-checked, or throws. deps: { fetchVerified(b, servers, opts), serverOrigin(s),
 * authorServers(pubkey) -> Promise<[server]>, usual: [server] }.
 */
export async function fetchArtifact(event, deps) {
  const manifest = parseManifest(event)
  const b = { sha256: manifest.hash, ext: "html", servers: [], author: manifest.publisher, size: null }
  const servers = [...new Set([...manifestServers(event), ...(await deps.authorServers(manifest.publisher).catch(() => [])), ...(deps.usual ?? [])].map(deps.serverOrigin).filter(Boolean))].slice(0, 8)
  if (!servers.length) throw new Error("its manifest names no server to fetch it from")
  const got = await deps.fetchVerified(b, servers, { maxBytes: MAX_ARTIFACT })
  if (!got) throw new Error("no server had its file (or every copy was the wrong file)")
  return new TextDecoder().decode(got.bytes)
}

/** The installed apps, kept per account in the shell's own localStorage: line -> { event, installedAt }. */
export function appStore(storage, account) {
  const KEY = `nv-napplet-apps:${account}`
  const read = () => { try { return JSON.parse(storage.getItem(KEY) || "{}") || {} } catch { return {} } }
  const write = all => storage.setItem(KEY, JSON.stringify(all))
  return {
    list: () => Object.entries(read()).map(([line, a]) => ({ line, ...a })).sort((a, b) => b.installedAt - a.installedAt),
    get: line => read()[line] ?? null,
    put: (event, now = Date.now()) => { const m = parseManifest(event), all = read(); all[nappletLine(m)] = { event, installedAt: now }; write(all) },
    remove: line => { const all = read(); delete all[line]; write(all) },
  }
}

/** A newer manifest in the catalog for an installed app (a new hash: a new napplet, asked again), or null. */
export function updateFor(installed, entries) {
  const e = entries.find(x => x.line === installed.line)
  if (!e || e.manifest.hash === parseManifest(installed.event).hash || e.event.created_at <= installed.event.created_at) return null
  return e
}

/**
 * After an update: the old version is another napplet (another hash), so its grant, its own storage and its bytes go.
 * The app's shared storage (nappletLine) stays: that is what carries over between versions. Same hash: nothing.
 */
export async function retireVersion(oldEvent, newHash, { grants, storage, artifacts }) {
  const old = parseManifest(oldEvent)
  if (old.hash === newHash) return
  const key = nappletKey(old)
  grants.remove(key)
  await storage.clear(key)
  await artifacts?.remove(old.hash)
}

/**
 * Remove: the app, every grant any version of it had, its storage (each version's and the shared one) and its kept
 * bytes. -> the grant keys removed. deps: { apps, grants, storage, artifacts }.
 */
export async function removeApp(line, { apps, grants, storage, artifacts }) {
  // Only "<line>:<64 hex>": a d tag can hold a colon, so "pub:foo:bar:<hash>" is another napplet, not a version of "pub:foo".
  const keys = Object.keys(grants.list()).filter(k => k.startsWith(`${line}:`) && /^[0-9a-f]{64}$/.test(k.slice(line.length + 1)))
  const hashes = new Set(keys.map(k => k.slice(line.length + 1)))
  const app = apps.get(line)
  if (app) hashes.add(parseManifest(app.event).hash)
  for (const k of keys) grants.remove(k)
  apps.remove(line)
  await storage.clear(line)
  for (const h of hashes) {
    const [publisher, ...d] = line.split(":")
    await storage.clear(nappletKey({ publisher, dTag: d.join(":"), hash: h }))
    await artifacts?.remove(h)
  }
  return keys
}
