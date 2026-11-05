// Settings › Relays: each relay's answer from this browser and why it didn't connect (parity N2; iPhone RelayProbe.swift,
// RelayFailReason.swift). Fake sockets and fetches: nothing goes out.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { httpReason, infoUrl, failReason, probeOnce, probeRelay, probeLine, noAnswer, SLOW_MS } from "../src/net/relay-probe.js"

/** A WebSocket stand-in: `script(ws)` decides what happens after it is made. */
const fakeWS = script => class {
  constructor(url) { this.url = url; this.sent = []; queueMicrotask(() => script(this)) }
  send(m) { this.sent.push(m) }
  close() { this.closed = true }
}

test("HTTP answers read as the iPhone's RelayFailReason, word for word", () => {
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Models/RelayFailReason.swift", import.meta.url), "utf8")
  for (const [status, text] of [[401, "refused (HTTP 401)"], [403, "refused (HTTP 403)"], [404, "no relay at this address (HTTP 404)"], [429, "rate-limited (HTTP 429)"],
    [200, "not a relay (answered with a web page)"], [503, "server error (HTTP 503)"], [418, "HTTP 418"]]) {
    assert.equal(httpReason(status), text)
    assert.ok(swift.includes(text.replace(/\d{3}/, "\\(status)")) || swift.includes(text), `${text} is the phone's`)
  }
  assert.equal(noAnswer(6000), "no answer in 6 s")
  assert.ok(swift.includes('"no answer in \\(Int(seconds)) s"'))
  assert.equal(httpReason(200, true), "not answering", "a relay that answers NIP-11 but not its socket")
})

test("the NIP-11 address of a relay, and none for what isn't one", () => {
  assert.equal(infoUrl("wss://relay.example.com/"), "https://relay.example.com/")
  assert.equal(infoUrl("ws://localhost:3355"), "http://localhost:3355/")
  assert.equal(infoUrl("https://example.com"), null)
  assert.equal(infoUrl("not a url"), null)
})

test("why it failed: offline, the HTTP answer, or not answering when the browser can't tell", async () => {
  assert.equal(await failReason("wss://x.example", { online: () => false }), "you're offline")
  const answer = (status, type = "text/html") => async () => ({ status, headers: { get: () => type } })
  assert.equal(await failReason("wss://x.example", { online: () => true, fetchFn: answer(404) }), "no relay at this address (HTTP 404)")
  assert.equal(await failReason("wss://x.example", { online: () => true, fetchFn: answer(200) }), "not a relay (answered with a web page)")
  assert.equal(await failReason("wss://x.example", { online: () => true, fetchFn: async () => { throw new TypeError("Failed to fetch") } }), "not answering")
  assert.equal(await failReason("https://x.example", { online: () => true }), "not a relay address")
})

test("a probe times the first answer to one REQ; nothing is signed or published", async () => {
  let t = 1000
  const WS = fakeWS(ws => { ws.onopen(); t += 120; ws.onmessage({ data: '["EOSE","nv-probe"]' }) })
  let made
  const r = await probeOnce("wss://ok.example", { WS: class extends WS { constructor(u) { super(u); made = this } }, now: () => t })
  assert.deepEqual(r, { ms: 120 })
  assert.deepEqual(made.sent.map(s => JSON.parse(s)[0]), ["REQ"])
  assert.ok(made.closed)
})

test("a socket that fails asks why; one that never answers says how long it waited", async () => {
  const failing = fakeWS(ws => ws.onerror())
  assert.deepEqual(await probeOnce("wss://down.example", { WS: failing, reason: async () => "refused (HTTP 403)" }), { why: "refused (HTTP 403)" })
  const silent = fakeWS(() => {})
  assert.deepEqual(await probeOnce("wss://slow.example", { WS: silent, timeoutMs: 30 }), { why: "no answer in 0 s" })
  assert.deepEqual(await probeOnce("https://nope", { WS: silent }), { why: "not a relay address" })
})

test("one retry before calling a relay down, as the iPhone", async () => {
  let n = 0
  const flaky = fakeWS(ws => { n++; if (n === 1) ws.onerror(); else { ws.onopen(); ws.onmessage({}) } })
  const r = await probeRelay("wss://blip.example", { WS: flaky, reason: async () => "connection dropped", sleep: async () => {} })
  assert.equal(n, 2); assert.ok(typeof r.ms === "number")
})

test("the row's line: ms, slow, the reason, or … while probing", () => {
  assert.deepEqual(probeLine(undefined), { text: "…", tone: "probing" })
  assert.deepEqual(probeLine({ ms: 120 }), { text: "120 ms", tone: "ok" })
  assert.deepEqual(probeLine({ ms: SLOW_MS + 1 }), { text: `${SLOW_MS + 1} ms · slow`, tone: "slow" })
  assert.deepEqual(probeLine({ why: "no such host" }), { text: "no such host", tone: "down" })
  const page = readFileSync(new URL("../src/screens/RelaysPage.jsx", import.meta.url), "utf8")
  assert.match(page, /<RelayName url=\{r\.url\} result=\{probes\[r\.url\]\} \/>/)
  assert.match(page, /probeRelay\(url\)/)
})
