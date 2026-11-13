// Dead emoji links (custom emoji v1, Logen 2026-11-13): each image of your sets is loaded once; one that doesn't load
// is looked for on other servers by its hash (a Blossom link names it: <server>/<sha256>.<ext>, BUD-01), on your media
// servers, the set author's (kind 10063) and the usual ones. A copy found elsewhere is checked against the hash before
// it is used. What no server has goes in the page's Dead links section. Nothing here is signed or published.
import { serverOrigin, fetchVerified, MAX_SERVERS } from "./blossom-uri.js"
import { uniq } from "./pool.js"

export const PROBE_MS = 10_000
export const PARALLEL = 6
/** Plan §4.1 cap for one emoji image. */
export const MAX_EMOJI_BYTES = 2 * 1024 * 1024
const IMAGE_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp", "avif", "svg"])

/** The hash a link names in its last path part (a Blossom link), or null. -> { sha256, ext } */
export function hashOfLink(url) {
  let u
  try { u = new URL(url) } catch { return null }
  const last = u.pathname.split("/").pop() ?? ""
  const m = /^([0-9a-fA-F]{64})(?:\.([A-Za-z0-9]{1,10}))?$/.exec(last)
  if (!m) return null
  const ext = (m[2] ?? "").toLowerCase()
  return { sha256: m[1].toLowerCase(), ext: IMAGE_EXT.has(ext) ? ext : "png" }
}

/** Servers to try for a dead link: yours, the author's, the usual ones, never the dead link's own host. */
export function otherServers(url, lists) {
  let own = null
  try { own = new URL(url).origin } catch {}
  return uniq(lists.flat().map(serverOrigin).filter(Boolean)).filter(s => new URL(s).origin !== own).slice(0, MAX_SERVERS)
}

/** Loads `url` as an image (no CORS needed). -> true when it drew, false on an error or after `ms`. Browser only. */
export function probeImage(url, ms = PROBE_MS) {
  return new Promise(resolve => {
    const Img = globalThis.Image
    if (!Img) return resolve(false)
    const img = new Img()
    let done = false
    const end = ok => { if (done) return; done = true; clearTimeout(timer); img.onload = img.onerror = null; resolve(ok) }
    const timer = setTimeout(() => end(false), ms)
    img.referrerPolicy = "no-referrer"
    img.onload = () => end(img.naturalWidth > 0)
    img.onerror = () => end(false)
    img.src = url
  })
}

/**
 * Each link's state: "ok" | { moved: url on another server, checked against its hash } | "dead". `servers(url)` -> the
 * server lists to try for it ([[origin]]); `onResult(url, state)` as each one settles. `probe` and `fetch` are for
 * tests. -> Map url -> state
 */
export async function checkLinks(urls, { servers = async () => [], probe = probeImage, fetch = globalThis.fetch, onResult = () => {}, parallel = PARALLEL } = {}) {
  const out = new Map()
  const queue = uniq(urls)
  const one = async url => {
    let state = "dead"
    if (await probe(url)) state = "ok"
    else {
      const h = hashOfLink(url)
      if (h) {
        const tryAt = otherServers(url, await servers(url).catch(() => []))
        const got = await fetchVerified({ sha256: h.sha256, ext: h.ext, size: null }, tryAt, { fetch, maxBytes: MAX_EMOJI_BYTES }).catch(() => null)
        if (got) state = { moved: `${got.server}/${h.sha256}.${h.ext}` }
      }
    }
    out.set(url, state)
    onResult(url, state)
  }
  const workers = Array.from({ length: Math.min(parallel, queue.length) }, async () => {
    while (queue.length) await one(queue.shift())
  })
  await Promise.all(workers)
  return out
}

/** The Dead links section: every emoji of `sets` whose link is dead, set by set. A saved copy in the vault is noted.
 *  -> [{ set, code, url, saved }] */
export function deadLinks(sets, states, savedFor = () => null) {
  const out = []
  for (const set of sets) for (const e of set.emoji)
    if (states.get(e.url) === "dead") out.push({ set, code: e.code, url: e.url, saved: !!savedFor(set, e) })
  return out
}
