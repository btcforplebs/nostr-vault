// The public post page's server: GET /thread/<nevent|note|naddr> -> the post and its replies as HTML (page.js), read
// from public relays (fetch.js). GET /p/<npub> -> the profile page (profile-page.js), from the same relays. nginx proxies /thread/ here (website/nginx.conf); run it with `npm run thread`.
// Pages are kept in memory for a while, so a link pasted into a busy chat costs the relays one read.
// A browser is sent on into the web app (page.js appLink); the page itself is for link previews.
import http from "node:http"
import { SimplePool } from "nostr-tools/pool"
import { parseTarget, renderMissing, renderPost, replyList } from "./page.js"
import { loadProfile, loadThread, safeRelay } from "./fetch.js"
import { parseProfileTarget, renderProfile, renderProfileMissing } from "./profile-page.js"

const PORT = Number(process.env.PORT || 8790)
const WAIT_MS = Number(process.env.THREAD_WAIT_MS || 3500) // per relay read; chat unfurlers give up after ~5-10 s
const FOUND_TTL = 10 * 60_000, MISSING_TTL = 60_000, MAX_CACHED = 500

/** Node 22's WebSocket fires "error" from inside close() when the socket was reset during the handshake, and
 *  nostr-tools calls close() from its onerror, so the two call each other until the stack overflows (RangeError) and
 *  the service restarts. Later Node versions don't. Here a second close() on the same socket does nothing. */
export function closeOnce(Base) {
  return class extends Base {
    #closing = false
    close(...args) {
      if (this.#closing) return
      this.#closing = true
      super.close(...args)
    }
  }
}

export const newPool = (Base = globalThis.WebSocket) => new SimplePool({ websocketImplementation: closeOnce(Base) })

const cache = new Map() // code -> { at, ttl, status, html }
const inflight = new Map() // code -> Promise

async function build(code) {
  const target = parseTarget(code)
  if (!target) return { status: 404, html: renderMissing({ code, valid: false }), ttl: FOUND_TTL }
  const pool = newPool()
  try {
    const query = (relays, filter) => pool.querySync(relays, filter, { maxWait: WAIT_MS }).catch(() => [])
    const { post, events, profiles } = await loadThread(target, query)
    if (!post) return { status: 404, html: renderMissing({ code, valid: true }), ttl: MISSING_TTL }
    return { status: 200, html: renderPost({ post, replies: replyList(post, events), profiles, code, hints: (target.relays ?? []).map(safeRelay).filter(Boolean) }), ttl: FOUND_TTL }
  } finally {
    pool.destroy()
  }
}

/** A profile page. One that no relay had a kind 0 for is still a working page (its link opens the app on that key),
 *  so it is a 200, kept for the shorter time. */
async function buildProfile(code) {
  const target = parseProfileTarget(code)
  if (!target) return { status: 404, html: renderProfileMissing({ code }), ttl: FOUND_TTL }
  const pool = newPool()
  try {
    const query = (relays, filter) => pool.querySync(relays, filter, { maxWait: WAIT_MS }).catch(() => [])
    const profile = await loadProfile(target, query)
    return { status: 200, html: renderProfile({ target, profile }), ttl: profile ? FOUND_TTL : MISSING_TTL }
  } finally {
    pool.destroy()
  }
}

/** `key`: "thread:<code>" or "p:<code>", so a post and a profile never share a cache entry. */
async function pageFor(key) {
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < hit.ttl) return hit
  if (!inflight.has(key)) {
    const [route, code] = [key.slice(0, key.indexOf(":")), key.slice(key.indexOf(":") + 1)]
    inflight.set(key, (route === "p" ? buildProfile(code) : build(code)).then(r => {
      cache.delete(key)
      cache.set(key, { ...r, at: Date.now() })
      if (cache.size > MAX_CACHED) cache.delete(cache.keys().next().value)
      return cache.get(key)
    }).finally(() => inflight.delete(key)))
  }
  return inflight.get(key)
}

const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://x")
  const m = /^\/(thread|p)\/([A-Za-z0-9:]{1,2000})\/?$/.exec(pathname)
  if (req.method !== "GET" && req.method !== "HEAD") { res.writeHead(405, { Allow: "GET, HEAD" }); return res.end() }
  if (!m) { res.writeHead(404, { "Content-Type": "text/plain" }); return res.end("not found") }
  try {
    const page = await pageFor(`${m[1]}:${m[2].replace(/^nostr:/i, "")}`)
    res.writeHead(page.status, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": page.status === 200 ? "public, max-age=300" : "public, max-age=60",
      "Content-Length": Buffer.byteLength(page.html),
    })
    res.end(req.method === "HEAD" ? undefined : page.html)
  } catch (err) {
    console.error("thread page:", err)
    res.writeHead(502, { "Content-Type": "text/plain" })
    res.end("relays unavailable")
  }
})

if (!process.env.THREAD_PAGE_NO_LISTEN) {
  server.listen(PORT, () => console.log(`thread pages on http://localhost:${PORT}/thread/<nevent> and /p/<npub>`))
}
