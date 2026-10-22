// The public post page's mesh photos (nostrvault.app/thread/, web-vault/thread-page/). A note photo its https server
// can't serve is read over FIPS from the vault its author's 10063 names (fipsmesh://), for any visitor, signed out.
// The page server checked the 10063 and wrote the photo's hash and those vaults on the <img> (data-x, data-vaults);
// this script reads nothing else and asks no one else. The reader (photo-reader.js: a throwaway key, the public seeds
// only, no WebRTC) starts as the page opens when the shared post has such a photo, so the seed handshake is done by
// the time the https link fails, and stops once nothing is left to read. A failed post photo asks the page server's
// copy (PHOTO_CACHE_PATH, which a warm server node keeps for photos it has already read) and the mesh at once, and
// shows whichever answers first. A reply's photo (data-mesh-on="error") is a fallback only: it starts no reader at
// page open and asks no server copy, just its own author's vaults once its https link fails.
const HEX = /^[0-9a-f]{64}$/
const MAX_VAULTS = 3 // a 10063 can list any number; the page server already keeps the first few
const READ_TIMEOUT_MS = 45_000 // per vault: a cold mesh route can take a while
export const MAX_PHOTOS = 8 // mesh reads per page; the rest keep their dead link
export const MAX_PARALLEL = 2
export const MAX_PHOTO_BYTES = 16 * 1024 * 1024 // a share-page photo, not a 64 MiB blob
export const MAX_PAGE_BYTES = 48 * 1024 * 1024
const IDLE_STOP_MS = 15_000 // lazy photos fail one by one: keep the reader (one key, one seed handshake) a while
export const LOADING_TEXT = "Loading image over FIPS…"
export const FAILED_TEXT = "Couldn't reach the owner's vault"
/** The page server's copy of a mesh photo, by hash (web-vault/thread-page/photo-cache.js). */
export const PHOTO_CACHE_PATH = "/thread/photo/"

/** Loads the server's copy of photo `x` in a detached <img>: its URL once it shows, null when there is none. */
function loadCachedImage(x, signal) {
  if (typeof Image === "undefined") return Promise.resolve(null)
  const url = PHOTO_CACHE_PATH + x
  return new Promise(resolve => {
    const probe = new Image()
    probe.onload = () => resolve(probe.naturalWidth > 0 ? url : null)
    probe.onerror = () => resolve(null)
    signal.addEventListener("abort", () => { probe.src = ""; resolve(null) }, { once: true })
    probe.src = url
  })
}

/** The first of `ps` to resolve to something; null once all resolved to nothing (or threw). */
function firstFound(ps) {
  return new Promise(resolve => {
    let left = ps.length
    const miss = () => { if (--left === 0) resolve(null) }
    for (const p of ps) p.then(v => (v ? resolve(v) : miss()), miss)
  })
}

/**
 * While a photo reads over the mesh its dead https <img> (Chrome's broken-image icon) is hidden behind a card that
 * says so; the card goes when the photo loads and says why when it doesn't. The page styles .mesh-ph.
 */
function placeholder(doc, img) {
  const shown = img.closest?.("a") ?? img // the link too: a tap on the card mustn't open the dead URL
  const mk = (img.ownerDocument ?? doc)?.createElement?.bind(img.ownerDocument ?? doc)
  if (!mk || !shown.parentNode) return () => {}
  const card = mk("div")
  card.className = "mesh-ph"
  card.setAttribute("role", "status")
  const spin = mk("span")
  spin.className = "spin"
  spin.setAttribute("aria-hidden", "true")
  const text = mk("span")
  text.textContent = LOADING_TEXT
  card.append(spin, text)
  card.dataset.state = "loading"
  shown.parentNode.insertBefore(card, shown)
  shown.hidden = true
  return state => {
    if (state === "loaded") { card.remove(); shown.hidden = false; return }
    card.dataset.state = "failed"
    spin.remove()
    text.textContent = FAILED_TEXT
  }
}

/** The hash and vaults the page wrote on an <img>, or undefined when it has none usable. */
export function meshTarget(img) {
  const x = String(img.dataset?.x ?? "").toLowerCase()
  const vaults = [...new Set(String(img.dataset?.vaults ?? "").toLowerCase().split(",").filter(v => HEX.test(v)))].slice(0, MAX_VAULTS)
  return HEX.test(x) && vaults.length ? { x, vaults, fallback: img.dataset?.meshOn === "error" } : undefined
}

/**
 * Wires every mesh-capable photo on `doc`: one that has already failed is read now, the rest on their first error;
 * the reader starts right away when there is any. At most MAX_PHOTOS photos, MAX_PARALLEL at a time, MAX_PHOTO_BYTES
 * each and MAX_PAGE_BYTES in all. `start(getPhotoVaults)` starts the reader (tests pass a fake); `loadCached(x, signal)`
 * resolves the server copy's URL or null; `toUrl(bytes, type)` makes the blob: URL;
 * `onLeave(fn)` runs fn when the page goes away (revokes the URLs, stops the reader).
 */
export function wireMeshPhotos(doc, {
  start = getPhotoVaults => import("./photo-reader.js").then(m => m.startPhotoReader({ getPhotoVaults })),
  loadCached = loadCachedImage,
  toUrl = (bytes, type) => URL.createObjectURL(new Blob([bytes], { type })),
  revoke = url => URL.revokeObjectURL(url),
  onLeave = fn => globalThis.addEventListener?.("pagehide", fn, { once: true }),
  timeoutMs = READ_TIMEOUT_MS,
  idleStopMs = IDLE_STOP_MS,
  limits: { photos = MAX_PHOTOS, parallel = MAX_PARALLEL, photoBytes = MAX_PHOTO_BYTES, pageBytes = MAX_PAGE_BYTES } = {},
} = {}) {
  const allowed = new Set() // only the vaults this page named
  const urls = []
  const waiting = []
  let reader, active = 0, used = 0, leaving = false, idle
  const getReader = () => (reader ??= start(() => allowed).catch(e => { reader = undefined; throw e }))
  const stopReader = () => {
    clearTimeout(idle)
    const r = reader
    reader = undefined
    r?.then(x => x.stop?.()).catch(() => {})
  }

  /** The photo over the mesh, vault by vault: its blob: URL, or null. `stop` aborts it (the server copy won). */
  async function readMesh(t, stop) {
    try {
      const r = await getReader()
      for (const vault of t.vaults) {
        if (leaving || stop.aborted || used >= pageBytes) break
        const ctl = new AbortController()
        const quit = () => ctl.abort()
        stop.addEventListener("abort", quit, { once: true })
        let seen = 0
        try {
          const got = await r.getBlob(vault, t.x, {
            timeoutMs,
            signal: ctl.signal,
            onProgress: n => { used += n - seen; seen = n; if (n > photoBytes || used > pageBytes) ctl.abort() },
          })
          if (got.bytes.length > photoBytes) throw new Error("too large")
          if (stop.aborted) return null
          const url = toUrl(got.bytes, got.type)
          urls.push(url)
          return url
        } catch { /* the next vault */ } finally { stop.removeEventListener("abort", quit) }
      }
    } catch { /* no reader */ }
    return null
  }

  async function readOne(img, t) {
    const stop = new AbortController()
    const fromServer = t.fallback ? Promise.resolve(null) : Promise.resolve().then(() => loadCached(t.x, stop.signal)).catch(() => null)
    const url = await firstFound([fromServer, readMesh(t, stop.signal)])
    stop.abort() // the other one stops
    if (!url) return "failed"
    img.src = url
    const link = img.closest?.("a")
    if (link) link.href = url // the tap opens the photo that loaded, not the dead link
    return "loaded"
  }

  function next() {
    while (active < parallel && waiting.length) {
      const { img, t, done, settle } = waiting.shift()
      active++
      clearTimeout(idle)
      readOne(img, t).catch(() => "failed").then(state => {
        img.dataset.mesh = state
        settle(state)
        active--
        done()
        next()
      })
    }
    // Nothing left to read: stop after a quiet while; a later failure starts a fresh reader.
    if (!active && !waiting.length && reader) quietStop()
  }
  function quietStop() { clearTimeout(idle); idle = setTimeout(stopReader, idleStopMs); idle?.unref?.() }

  let queued = 0
  function read(img) {
    const t = meshTarget(img)
    if (!t || img.dataset.mesh || leaving) return
    if (queued >= photos) { img.dataset.mesh = "skipped"; return }
    queued++
    img.dataset.mesh = "loading"
    const settle = placeholder(doc, img)
    for (const v of t.vaults) allowed.add(v)
    return new Promise(done => { waiting.push({ img, t, done, settle }); next() })
  }

  onLeave(() => {
    leaving = true
    waiting.length = 0
    stopReader()
    for (const u of urls.splice(0)) revoke(u)
  })

  const reads = []
  const marked = [...doc.querySelectorAll("img[data-x][data-vaults]")].filter(img => meshTarget(img))
  // Start the reader now, while the https links load: when one fails, the seed handshake is already done. Reply
  // photos (fallback) don't: a page whose only mesh photos are replies' opens no connection until one fails.
  if (marked.some(img => !meshTarget(img).fallback)) { getReader().catch(() => {}); if (!active && !waiting.length) quietStop() }
  for (const img of marked) {
    if (img.complete && img.naturalWidth === 0) reads.push(read(img))
    else img.addEventListener("error", () => read(img), { once: true })
  }
  return Promise.all(reads)
}

if (typeof document !== "undefined") wireMeshPhotos(document)
