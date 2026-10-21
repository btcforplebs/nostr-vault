// A link card's OpenGraph preview, fetched by this browser itself (LinkPreviewService.swift): no preview server, no
// proxy, no third-party service. Most sites send no CORS header, so the fetch fails and the card stays a plain link;
// the few that allow it get the iPhone's image, title and description. Only public https pages are asked: a
// stranger's note must not make the browser knock on loopback or the LAN. No cookies and no referrer go with it.
import { isPublicRelay } from "./polls.js"

const MAX_BYTES = 50_000 // as iOS: the <head> is near the top, the rest of a page isn't read
const TIMEOUT_MS = 10_000
const MAX_PARALLEL = 4
const MAX_CACHED = 200
const MAX_TEXT = 300

/** Only a public https page is fetched (isPublicRelay's host rules, read as https). */
export function canPreview(url) {
  const raw = String(url ?? "").trim()
  if (!/^https:\/\//i.test(raw)) return false
  return isPublicRelay(raw.replace(/^https:/i, "wss:"))
}

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " }
/** HTML attribute text, decoded (&amp;, &#39;, &#x2019; …). An unknown or out-of-range entity stays as it was. */
export function decodeEntities(s) {
  return String(s).replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (m, e) => {
    if (e[0] !== "#") return ENTITIES[e.toLowerCase()] ?? m
    const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
    return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m
  })
}

const clean = s => {
  const t = decodeEntities(s).replace(/\s+/g, " ").trim()
  return t ? t.slice(0, MAX_TEXT) : null
}
const attr = (tag, name) => {
  const m = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)
  return m ? (m[1] ?? m[2] ?? m[3]) : null
}

/** <meta property="og:…"> (either attribute order, name= too, as some sites write it) and <title>, as iOS reads them.
 *  -> { title, description, image, siteName } or null when there is no title. `image` is an absolute https URL. */
export function parseOpenGraph(html, pageUrl) {
  const og = {}
  for (const [tag] of String(html).matchAll(/<meta\b[^>]*>/gi)) {
    const key = (attr(tag, "property") ?? attr(tag, "name") ?? "").toLowerCase()
    const content = attr(tag, "content")
    if (!key.startsWith("og:") || !content || og[key.slice(3)] != null) continue
    og[key.slice(3)] = content
  }
  const title = clean(og.title ?? /<title[^>]*>([^<]*)<\/title>/i.exec(html)?.[1] ?? "")
  if (!title) return null
  let image = null
  if (og.image) {
    try {
      const u = new URL(decodeEntities(og.image).trim(), pageUrl)
      if (canPreview(u.href)) image = u.href
    } catch { /* no image */ }
  }
  return { title, description: og.description ? clean(og.description) : null, image, siteName: og.site_name ? clean(og.site_name) : null }
}

/** The first MAX_BYTES of a response body as text. */
async function head(res) {
  if (!res.body?.getReader) return (await res.text()).slice(0, MAX_BYTES)
  const reader = res.body.getReader(), chunks = []
  let size = 0
  while (size < MAX_BYTES) {
    const { done, value } = await reader.read()
    if (done) break
    chunks.push(value); size += value.length
  }
  reader.cancel().catch(() => {})
  const all = new Uint8Array(Math.min(size, MAX_BYTES))
  let at = 0
  for (const c of chunks) { const part = c.subarray(0, all.length - at); all.set(part, at); at += part.length; if (at >= all.length) break }
  return new TextDecoder().decode(all)
}

/** One page's preview, or null: CORS refused, not HTML, not 2xx, too slow, or no title. Never throws. */
export async function fetchPreview(url, { fetch: get = globalThis.fetch } = {}) {
  if (!canPreview(url)) return null
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS)
  try {
    const res = await get(url, { mode: "cors", credentials: "omit", referrerPolicy: "no-referrer", redirect: "follow", signal: ctl.signal, headers: { Accept: "text/html" } })
    if (!res.ok || !/text\/html/i.test(res.headers.get("content-type") ?? "")) return null
    // A redirect may land somewhere this browser shouldn't read from, and relative og:image resolves against it.
    const landed = res.url || url
    if (!canPreview(landed)) return null
    return parseOpenGraph(await head(res), landed)
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

// One fetch per URL per page load, the result kept (a miss too, as iOS's failedURLs), a few at a time.
const cache = new Map()
let running = 0
const waiting = []
const next = () => { while (running < MAX_PARALLEL && waiting.length) { running++; waiting.shift()() } }

/** The cached preview promise for `url`, starting the fetch if there is none. */
export function preview(url, opts) {
  let p = cache.get(url)
  if (p) return p
  p = new Promise(start => waiting.push(start))
    .then(() => fetchPreview(url, opts))
    .finally(() => { running--; next() })
  cache.set(url, p)
  if (cache.size > MAX_CACHED) cache.delete(cache.keys().next().value)
  next()
  return p
}

/** The preview if it has already arrived (a re-render shows it at once), else undefined. */
const settled = new Map()
export function cachedPreview(url) { return settled.get(url) }
export function loadPreview(url, opts) {
  return preview(url, opts).then(meta => {
    settled.set(url, meta)
    if (settled.size > MAX_CACHED) settled.delete(settled.keys().next().value)
    return meta
  })
}

/** Tests only. */
export function resetPreviews() { cache.clear(); settled.clear(); waiting.length = 0; running = 0 }
