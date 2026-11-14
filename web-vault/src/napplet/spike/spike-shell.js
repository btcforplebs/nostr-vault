// P0 spike shell (dev page napplet-spike.html, never built into the app). Hosts the sample Note Drafts napplet and the
// bench napplet with in-memory answers signed by a throwaway key made on every load. Results land in document.title
// as JSON so headless Chrome can read them (GUIDES/WEB_VAULT_CHROME_TESTING.md).
import { generateSecretKey, getPublicKey, finalizeEvent, matchFilters } from "nostr-tools"
import { mountNapplet } from "../host.js"
import noteDrafts from "../../../napplets/note-drafts/index.html?raw"
import bench from "../../../napplets/bench/index.html?raw"

const sk = generateSecretKey() // throwaway, never stored
const pubkey = getPublicKey(sk)
const events = []
const stats = { queryHandlerMs: [] }

// 200 notes shaped like a real page: 40-900 characters, a few tags each.
const words = "vault relay note zap nostr photo garden morning signal bitcoin coffee mesh river light stream key".split(" ")
for (let i = 0; i < 200; i++) {
  const len = 40 + ((i * 97) % 860)
  let content = ""
  while (content.length < len) content += words[(content.length * 7 + i) % words.length] + " "
  const tags = Array.from({ length: 2 + (i % 6) }, (_, j) => (j % 2 ? ["t", words[(i + j) % words.length]] : ["p", pubkey]))
  events.push(finalizeEvent({ kind: 1, created_at: 1763000000 - i * 60, tags, content }, sk))
}

// Fixtures for resource: noisy JPEG thumbnails, big zero blobs, and a 2 s VP8 clip recorded from a canvas.
const thumbs = new Map(), blobs = new Map()
let clip = null
async function makeFixtures() {
  const c = Object.assign(document.createElement("canvas"), { width: 320, height: 320 }), g = c.getContext("2d")
  for (let i = 0; i < 30; i++) {
    const img = g.createImageData(320, 320)
    for (let p = 0; p < img.data.length; p += 4) { const v = (Math.random() * 255) | 0; img.data.set([v, (v * i) & 255, 128, 255], p) }
    g.putImageData(img, 0, 0)
    thumbs.set(i, await new Promise((r) => c.toBlob(r, "image/jpeg", 0.6)))
  }
  for (const mb of [5, 25, 50]) blobs.set(mb, new Blob([new Uint8Array(mb * 1048576)], { type: "application/octet-stream" }))
  const v = Object.assign(document.createElement("canvas"), { width: 320, height: 180 }), vg = v.getContext("2d")
  const rec = new MediaRecorder(v.captureStream(30), { mimeType: "video/webm;codecs=vp8" })
  const parts = []
  rec.ondataavailable = (e) => parts.push(e.data)
  const draw = setInterval(() => { vg.fillStyle = `hsl(${(performance.now() / 5) % 360} 80% 50%)`; vg.fillRect(0, 0, 320, 180) }, 33)
  rec.start()
  await new Promise((r) => setTimeout(r, 2000))
  await new Promise((r) => { rec.onstop = r; rec.stop() })
  clearInterval(draw)
  clip = new Blob(parts, { type: "video/webm;codecs=vp8" })
}

function resourceFor(url) {
  let m
  if ((m = /^nvtest:thumb\/(\d+)$/.exec(url))) return thumbs.get(+m[1])
  if ((m = /^nvtest:blob\/(\d+)$/.exec(url))) return blobs.get(+m[1])
  if (url === "nvtest:clip.webm") return clip
  return null
}

// One handler per NAP domain. Each returns the reply envelope (or undefined to answer later).
const storageOf = new Map() // per napplet: dTag + artifact hash, as NIP-5D scopes it
const handlers = (domains) => ({
  shell: (m) => (m.type === "shell.ready" ? { type: "shell.init", capabilities: { domains }, services: [] } : undefined),
  identity: (m) => (m.type === "identity.getPublicKey" ? { type: "identity.getPublicKey.result", id: m.id, pubkey } : undefined),
  theme: (m) => (m.type === "theme.get" ? { type: "theme.get.result", id: m.id, theme: { mode: "dark", accent: "#e67326" } } : undefined),
  storage: (m, napplet) => {
    const key = napplet.dTag + ":" + napplet.hash
    if (!storageOf.has(key)) storageOf.set(key, new Map())
    const s = storageOf.get(key)
    if (m.type === "storage.get") return { type: "storage.get.result", id: m.id, value: s.get(m.key) ?? null }
    if (m.type === "storage.set") {
      s.set(m.key, String(m.value))
      if (m.key === "bench") report({ bench: JSON.parse(m.value) })
      return { type: "storage.set.result", id: m.id }
    }
    if (m.type === "storage.remove") { s.delete(m.key); return { type: "storage.remove.result", id: m.id } }
    if (m.type === "storage.keys") return { type: "storage.keys.result", id: m.id, keys: [...s.keys()] }
  },
  outbox: (m) => {
    if (m.type === "outbox.query") {
      const t = performance.now()
      const limit = Math.min(...m.filters.map((f) => f.limit ?? 500))
      const found = events.filter((e) => matchFilters(m.filters, e)).slice(0, limit).map((event) => ({ event }))
      stats.queryHandlerMs.push(performance.now() - t)
      return { type: "outbox.query.result", id: m.id, events: found }
    }
    if (m.type === "outbox.publish") {
      // The shell signs; the napplet never sees a key. Only kind 1 is allowed in the spike.
      if (m.event?.kind !== 1) return { type: "outbox.publish.result", id: m.id, ok: false, error: "kind not allowed" }
      const event = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content: String(m.event.content) }, sk)
      events.unshift(event)
      return { type: "outbox.publish.result", id: m.id, ok: true, event }
    }
  },
  resource: (m) => {
    if (m.type === "resource.bytes") {
      const blob = resourceFor(m.url)
      return blob ? { type: "resource.bytes.result", id: m.id, blob } : { type: "resource.bytes.error", id: m.id, error: "not-found" }
    }
    if (m.type === "resource.bytesMany") {
      const items = m.requests.map(({ url }) => { const blob = resourceFor(url); return blob ? { url, ok: true, blob, mime: blob.type } : { url, ok: false, error: "not-found" } })
      return { type: "resource.bytesMany.result", id: m.id, items }
    }
    if (m.type === "resource.info") return { type: "resource.info.result", id: m.id, info: { schemes: [{ scheme: "nvtest" }] } }
  },
})

const results = {}
function report(part) {
  Object.assign(results, part)
  const q = stats.queryHandlerMs
  results.shell_query_handler_ms_median = q.length ? +[...q].sort((a, b) => a - b)[q.length >> 1].toFixed(2) : null
  document.title = JSON.stringify(results)
}

async function start() {
  const t = performance.now()
  await makeFixtures()
  results.fixtures_ms = +(performance.now() - t).toFixed(0)
  const drafts = ["shell", "identity", "storage", "outbox", "theme"]
  const benchDomains = ["shell", "identity", "storage", "outbox", "resource"]
  const m1 = await mountNapplet({ html: noteDrafts, dTag: "nv-note-drafts", domains: drafts, handlers: handlers(drafts), container: document.getElementById("drafts"), onRevoke: (why) => report({ drafts_revoked: why }) })
  const tb = performance.now()
  const m2 = await mountNapplet({ html: bench, dTag: "nv-p0-bench", domains: benchDomains, handlers: handlers(benchDomains), container: document.getElementById("bench"), onRevoke: (why) => report({ bench_revoked: why }) })
  m2.frame.addEventListener("load", () => report({ bench_frame_load_ms: +(performance.now() - tb).toFixed(1) }), { once: true })
  report({ drafts_hash: m1.hash, bench_hash: m2.hash, srcdoc_kb: Math.round(m2.frame.srcdoc.length / 1024) })
  globalThis.__spike = { m1, m2, events, report }
}
start()
