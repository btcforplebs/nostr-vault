// The public post page's mesh photos (nostrvault.app/thread/, web-vault/thread-page/). A note photo its https server
// can't serve is read over FIPS from the vault its author's 10063 names (fipsmesh://), for any visitor, signed out.
// The page server checked the 10063 and wrote the photo's hash and those vaults on the <img> (data-x, data-vaults);
// this script reads nothing else and asks no one else. The reader (photo-reader.js: a throwaway key, the public seeds
// only, no WebRTC) loads only when such a photo fails, and only once per page.
const HEX = /^[0-9a-f]{64}$/
const MAX_VAULTS = 3 // a 10063 can list any number; the page server already keeps the first few
const READ_TIMEOUT_MS = 45_000 // per vault: a cold mesh route can take a while

/** The hash and vaults the page wrote on an <img>, or undefined when it has none usable. */
export function meshTarget(img) {
  const x = String(img.dataset?.x ?? "").toLowerCase()
  const vaults = [...new Set(String(img.dataset?.vaults ?? "").toLowerCase().split(",").filter(v => HEX.test(v)))].slice(0, MAX_VAULTS)
  return HEX.test(x) && vaults.length ? { x, vaults } : undefined
}

/**
 * Wires every mesh-capable photo on `doc`: one that has already failed is read now, the rest on their first error.
 * `start(getPhotoVaults)` starts the reader (tests pass a fake); `toUrl(bytes, type)` makes the blob: URL.
 */
export function wireMeshPhotos(doc, {
  start = getPhotoVaults => import("./photo-reader.js").then(m => m.startPhotoReader({ getPhotoVaults })),
  toUrl = (bytes, type) => URL.createObjectURL(new Blob([bytes], { type })),
  timeoutMs = READ_TIMEOUT_MS,
} = {}) {
  const allowed = new Set() // only the vaults this page named
  let reader
  const getReader = () => (reader ??= start(() => allowed).catch(e => { reader = undefined; throw e }))

  async function read(img) {
    const t = meshTarget(img)
    if (!t || img.dataset.mesh) return
    img.dataset.mesh = "loading"
    for (const v of t.vaults) allowed.add(v)
    try {
      const r = await getReader()
      for (const vault of t.vaults) {
        try {
          const got = await r.getBlob(vault, t.x, { timeoutMs })
          const url = toUrl(got.bytes, got.type)
          img.src = url
          const link = img.closest?.("a")
          if (link) link.href = url // the tap opens the photo that loaded, not the dead link
          img.dataset.mesh = "loaded"
          return
        } catch { /* the next vault */ }
      }
    } catch { /* no reader */ }
    img.dataset.mesh = "failed"
  }

  const reads = []
  for (const img of doc.querySelectorAll("img[data-x][data-vaults]")) {
    if (img.complete && img.naturalWidth === 0) reads.push(read(img))
    else img.addEventListener("error", () => read(img), { once: true })
  }
  return Promise.all(reads)
}

if (typeof document !== "undefined") wireMeshPhotos(document)
