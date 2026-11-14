// napplet-sw.js nv-stream path: only a <video>/<audio> fetch is answered, never a navigation, and the answer is
// always typed video/* or audio/* (a document there would skip the napplet origin's CSP header).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const SRC = readFileSync(new URL("../public/napplet-sw.js", import.meta.url), "utf8")
const ORIGIN = "https://n-0123456789abcdef0123456789abcdef.example"

function load(pageType) {
  const handlers = {}
  const client = { id: "c1", postMessage: (msg, [port]) => port.postMessage({ ok: true, buf: new Uint8Array(msg.end - msg.start + 1).buffer, size: 100, type: pageType }) }
  const self = { addEventListener: (k, f) => { handlers[k] = f }, skipWaiting() {}, clients: { claim() {}, matchAll: async () => [client] } }
  vm.runInNewContext(SRC, { self, location: new URL(ORIGIN + "/napplet-frame.html"), URL, Response, MessageChannel, setTimeout, clearTimeout, Number, Math, Infinity, String, Promise })
  return handlers.fetch
}
async function fire(fetch, { mode = "no-cors", destination = "video" } = {}) {
  let out
  const request = { url: ORIGIN + "/nv-stream/abcdefabcdefabcdef", method: "GET", mode, destination, headers: new Headers({ range: "bytes=0-9" }) }
  fetch({ request, clientId: "c1", respondWith: p => { out = p } })
  return out && await out
}

test("napplet-sw: a video fetch of nv-stream gets 206 bytes typed as the page said", async () => {
  const r = await fire(load("video/mp4"))
  assert.equal(r.status, 206)
  assert.equal(r.headers.get("content-type"), "video/mp4")
})
test("napplet-sw: a navigation to nv-stream is refused (no CSP-less document)", async () => {
  const r = await fire(load("text/html"), { mode: "navigate", destination: "document" })
  assert.equal(r.type, "error")
})
test("napplet-sw: a non-media destination (iframe, script) is refused", async () => {
  for (const destination of ["iframe", "script", "document", ""]) {
    const r = await fire(load("video/mp4"), { destination })
    assert.equal(r.type, "error", destination)
  }
})
test("napplet-sw: a page-posted non-media type is forced to a media type", async () => {
  for (const [dest, t] of [["video", "text/html"], ["audio", "image/svg+xml"], ["video", ""]]) {
    const r = await fire(load(t), { destination: dest })
    assert.match(r.headers.get("content-type"), dest === "audio" ? /^audio\// : /^video\//, t)
  }
  const r = await fire(load("audio/ogg"), { destination: "audio" })
  assert.equal(r.headers.get("content-type"), "audio/ogg")
})
