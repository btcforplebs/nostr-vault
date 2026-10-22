// The public post page's server: GET /thread/<nevent|note|naddr> -> the post and its replies as HTML (page.js), read
// from public relays (fetch.js). nginx proxies /thread/ here (website/nginx.conf); run it with `npm run thread`.
// Pages are kept in memory for a while, so a link pasted into a busy chat costs the relays one read.
import http from "node:http"
import { SimplePool } from "nostr-tools/pool"
import { parseTarget, renderMissing, renderPost, replyList } from "./page.js"
import { loadThread } from "./fetch.js"

const PORT = Number(process.env.PORT || 8790)
const WAIT_MS = Number(process.env.THREAD_WAIT_MS || 3500) // per relay read; chat unfurlers give up after ~5-10 s
const FOUND_TTL = 10 * 60_000, MISSING_TTL = 60_000, MAX_CACHED = 500

const cache = new Map() // code -> { at, ttl, status, html }
const inflight = new Map() // code -> Promise

async function build(code) {
  const target = parseTarget(code)
  if (!target) return { status: 404, html: renderMissing({ code, valid: false }), ttl: FOUND_TTL }
  const pool = new SimplePool()
  try {
    const query = (relays, filter) => pool.querySync(relays, filter, { maxWait: WAIT_MS }).catch(() => [])
    const { post, events, profiles, vaults } = await loadThread(target, query)
    if (!post) return { status: 404, html: renderMissing({ code, valid: true }), ttl: MISSING_TTL }
    return { status: 200, html: renderPost({ post, replies: replyList(post, events), profiles, code, vaults }), ttl: FOUND_TTL }
  } finally {
    pool.destroy()
  }
}

async function pageFor(code) {
  const hit = cache.get(code)
  if (hit && Date.now() - hit.at < hit.ttl) return hit
  if (!inflight.has(code)) {
    inflight.set(code, build(code).then(r => {
      cache.delete(code)
      cache.set(code, { ...r, at: Date.now() })
      if (cache.size > MAX_CACHED) cache.delete(cache.keys().next().value)
      return cache.get(code)
    }).finally(() => inflight.delete(code)))
  }
  return inflight.get(code)
}

const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://x")
  const m = /^\/thread\/([A-Za-z0-9:]{1,2000})\/?$/.exec(pathname)
  if (req.method !== "GET" && req.method !== "HEAD") { res.writeHead(405, { Allow: "GET, HEAD" }); return res.end() }
  if (!m) { res.writeHead(404, { "Content-Type": "text/plain" }); return res.end("not found") }
  try {
    const page = await pageFor(m[1].replace(/^nostr:/i, ""))
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

server.listen(PORT, () => console.log(`thread pages on http://localhost:${PORT}/thread/<nevent>`))
