// The napplet origin's service worker (plan P2; public/napplet-frame.html registers it, src/napplet/origin.js). A
// napplet origin serves only its loader page and this file; every other request from the napplet's frame (fetch, an
// image, a worker script, anything the frame's CSP might let past) gets a network error here, before the network.
// Not the vault's sw.js: that one lives on the vault's own origin and never sees a napplet.
// One more path, nv-stream/<id> (csp.js STREAM_PATH): a <video> or <audio> the napplet points there is answered
// here, part by part, with bytes the napplet's own page fetched through the shell (NAP-RESOURCE ranges). The network
// is never asked: a part comes from the page or the request fails. So a long video plays while it comes.
const OWN = /\/(napplet-frame\.html|napplet-sw\.js)$/
const STREAM = /\/nv-stream\/([A-Za-z0-9]{16,64})$/
const PART = 4 * 1024 * 1024, WAIT_MS = 60000
// Only a <video>/<audio> fetch is answered, and always typed as media: a navigation or a frame there would be a
// document from the page's bytes without this origin's CSP header.
const MEDIA_DEST = new Set(["video", "audio"]), MEDIA_TYPE = /^(video|audio)\/[\w.+-]+$/
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()))
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url)
  if (u.origin === location.origin && OWN.test(u.pathname) && !u.search) return
  const s = u.origin === location.origin && !u.search && e.request.method === "GET" &&
    e.request.mode !== "navigate" && MEDIA_DEST.has(e.request.destination) && STREAM.exec(u.pathname)
  e.respondWith(s ? stream(e, s[1]).catch(() => Response.error()) : Response.error())
})

// Ask a page of this origin for bytes start..end of stream `id` -> { ok, buf, size, type } (or ok: false).
function ask(client, want) {
  return new Promise(resolve => {
    const ch = new MessageChannel(), t = setTimeout(() => { ch.port1.close(); resolve({ ok: false }) }, WAIT_MS)
    ch.port1.onmessage = m => { clearTimeout(t); ch.port1.close(); resolve(m.data || { ok: false }) }
    client.postMessage({ type: "nv-stream.want", ...want }, [ch.port2])
  })
}
async function stream(e, id) {
  const r = /^bytes=(\d+)-(\d*)$/.exec(e.request.headers.get("range") || "bytes=0-")
  if (!r) return Response.error()
  const start = Number(r[1]), end = Math.min(r[2] ? Number(r[2]) : Infinity, start + PART - 1)
  if (end < start) return new Response(null, { status: 416 })
  const all = await self.clients.matchAll({ type: "window" })
  const first = all.filter(c => c.id === e.clientId)
  for (const c of [...first, ...all.filter(c => c.id !== e.clientId)]) {
    const got = await ask(c, { id, start, end })
    if (!got || !got.ok) continue
    if (start >= got.size) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${got.size}` } })
    const n = got.buf.byteLength
    return new Response(got.buf, { status: 206, headers: { "Content-Range": `bytes ${start}-${start + n - 1}/${got.size}`, "Content-Length": String(n), "Accept-Ranges": "bytes", "Content-Type": mediaType(e.request.destination, got.type) } })
  }
  return Response.error()
}
function mediaType(dest, t) {
  const v = String(t || "").split(";")[0].trim().toLowerCase()
  return MEDIA_TYPE.test(v) && v.startsWith(dest + "/") ? v : dest === "audio" ? "audio/mpeg" : "video/mp4"
}
