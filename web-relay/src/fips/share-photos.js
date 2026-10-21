// The public post page's mesh photos (nostrvault.app/thread/, web-vault/thread-page/). A note photo its https server
// can't serve is read over FIPS from the vault its author's 10063 names (fipsmesh://), for any visitor, signed out.
// The page server checked the 10063 and wrote the photo's hash and those vaults on the <img> (data-x, data-vaults),
// for the shared post's own photos only (a reply's author can't make visitors join the mesh); this script reads
// nothing else and asks no one else. The reader (photo-reader.js: a throwaway key, the public seeds only, no WebRTC)
// loads only when such a photo fails, and stops once nothing is left to read.
const HEX = /^[0-9a-f]{64}$/
const MAX_VAULTS = 3 // a 10063 can list any number; the page server already keeps the first few
const READ_TIMEOUT_MS = 45_000 // per vault: a cold mesh route can take a while
export const MAX_PHOTOS = 8 // mesh reads per page; the rest keep their dead link
export const MAX_PARALLEL = 2
export const MAX_PHOTO_BYTES = 16 * 1024 * 1024 // a share-page photo, not a 64 MiB blob
export const MAX_PAGE_BYTES = 48 * 1024 * 1024

/** The hash and vaults the page wrote on an <img>, or undefined when it has none usable. */
export function meshTarget(img) {
  const x = String(img.dataset?.x ?? "").toLowerCase()
  const vaults = [...new Set(String(img.dataset?.vaults ?? "").toLowerCase().split(",").filter(v => HEX.test(v)))].slice(0, MAX_VAULTS)
  return HEX.test(x) && vaults.length ? { x, vaults } : undefined
}

/**
 * Wires every mesh-capable photo on `doc`: one that has already failed is read now, the rest on their first error.
 * At most MAX_PHOTOS photos, MAX_PARALLEL at a time, MAX_PHOTO_BYTES each and MAX_PAGE_BYTES in all.
 * `start(getPhotoVaults)` starts the reader (tests pass a fake); `toUrl(bytes, type)` makes the blob: URL;
 * `onLeave(fn)` runs fn when the page goes away (revokes the URLs, stops the reader).
 */
export function wireMeshPhotos(doc, {
  start = getPhotoVaults => import("./photo-reader.js").then(m => m.startPhotoReader({ getPhotoVaults })),
  toUrl = (bytes, type) => URL.createObjectURL(new Blob([bytes], { type })),
  revoke = url => URL.revokeObjectURL(url),
  onLeave = fn => globalThis.addEventListener?.("pagehide", fn, { once: true }),
  timeoutMs = READ_TIMEOUT_MS,
  limits: { photos = MAX_PHOTOS, parallel = MAX_PARALLEL, photoBytes = MAX_PHOTO_BYTES, pageBytes = MAX_PAGE_BYTES } = {},
} = {}) {
  const allowed = new Set() // only the vaults this page named
  const urls = []
  const waiting = []
  let reader, active = 0, used = 0, leaving = false
  const getReader = () => (reader ??= start(() => allowed).catch(e => { reader = undefined; throw e }))
  const stopReader = () => {
    const r = reader
    reader = undefined
    r?.then(x => x.stop?.()).catch(() => {})
  }

  async function readOne(img, t) {
    try {
      const r = await getReader()
      for (const vault of t.vaults) {
        if (leaving || used >= pageBytes) break
        const ctl = new AbortController()
        let seen = 0
        try {
          const got = await r.getBlob(vault, t.x, {
            timeoutMs,
            signal: ctl.signal,
            onProgress: n => { used += n - seen; seen = n; if (n > photoBytes || used > pageBytes) ctl.abort() },
          })
          if (got.bytes.length > photoBytes) throw new Error("too large")
          const url = toUrl(got.bytes, got.type)
          urls.push(url)
          img.src = url
          const link = img.closest?.("a")
          if (link) link.href = url // the tap opens the photo that loaded, not the dead link
          return "loaded"
        } catch { /* the next vault */ }
      }
    } catch { /* no reader */ }
    return "failed"
  }

  function next() {
    while (active < parallel && waiting.length) {
      const { img, t, done } = waiting.shift()
      active++
      readOne(img, t).then(state => {
        img.dataset.mesh = state
        active--
        done()
        next()
      })
    }
    if (!active && !waiting.length) stopReader() // a later failure starts a fresh one
  }

  let queued = 0
  function read(img) {
    const t = meshTarget(img)
    if (!t || img.dataset.mesh || leaving) return
    if (queued >= photos) { img.dataset.mesh = "skipped"; return }
    queued++
    img.dataset.mesh = "loading"
    for (const v of t.vaults) allowed.add(v)
    return new Promise(done => { waiting.push({ img, t, done }); next() })
  }

  onLeave(() => {
    leaving = true
    waiting.length = 0
    stopReader()
    for (const u of urls.splice(0)) revoke(u)
  })

  const reads = []
  for (const img of doc.querySelectorAll("img[data-x][data-vaults]")) {
    if (img.complete && img.naturalWidth === 0) reads.push(read(img))
    else img.addEventListener("error", () => read(img), { once: true })
  }
  return Promise.all(reads)
}

if (typeof document !== "undefined") wireMeshPhotos(document)
