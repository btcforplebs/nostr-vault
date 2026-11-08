// The web pairing screen's helpers: which QR decoder a browser gets (qr-decode.js), the device name in its code and
// the Your devices rows (pair-devices.js).
import { test } from "node:test"
import assert from "node:assert/strict"
import { pickDecoder, onceEach } from "../src/components/qr-decode.js"
import { browserDeviceName, deviceRows } from "../src/net/pair-devices.js"
import { npubEncode } from "nostr-tools/nip19"

test("BarcodeDetector with qr_code is used, and the JS decoder is not loaded", async () => {
  let loaded = false
  class BD { static async getSupportedFormats() { return ["qr_code", "ean_13"] } constructor(o) { assert.deepEqual(o, { formats: ["qr_code"] }) } async detect() { return [{ rawValue: "nvpair:v1?x" }] } }
  const r = await pickDecoder({ BD, loadJs: async () => { loaded = true } })
  assert.equal(r.kind, "native")
  assert.equal(await r.decode({}), "nvpair:v1?x")
  assert.equal(loaded, false)
})

test("no BarcodeDetector, or one without qr_code (Firefox, some Safari), loads the JS decoder", async () => {
  for (const BD of [undefined, class { static async getSupportedFormats() { return ["ean_13"] } }, class { static async getSupportedFormats() { throw new Error("x") } }]) {
    let loaded = 0
    const fakeCtx = { drawImage() {}, getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }) }
    const doc = { createElement: () => ({ width: 0, height: 0, getContext: () => fakeCtx }) }
    const r = await pickDecoder({ BD, doc, loadJs: async () => { loaded++; return (d, w, h) => (w === 800 && h === 600 ? { data: "code" } : null) } })
    assert.equal(r.kind, "js")
    assert.equal(loaded, 1)
    assert.equal(await r.decode({ videoWidth: 0, videoHeight: 0 }), null, "no frame yet")
    assert.equal(await r.decode({ videoWidth: 1600, videoHeight: 1200 }), "code", "scaled to 800 px")
  }
})

test("each code passes once while it stays in view, and again after a gap", () => {
  let t = 0
  const got = []
  const pass = onceEach(x => got.push(x), { gapMs: 3000, now: () => t })
  pass("a"); t = 250; pass("a"); t = 500; pass(null); pass("b"); t = 750; pass("a")
  t = 5000; pass("a")
  assert.deepEqual(got, ["a", "b", "a", "a"])
})

test("the device name is the browser and the device it runs on", () => {
  const mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
  assert.equal(browserDeviceName(mac), "Chrome on Mac")
  assert.equal(browserDeviceName("Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"), "Firefox on Linux")
  assert.equal(browserDeviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"), "Safari on iPhone")
  assert.equal(browserDeviceName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36 Edg/140.0"), "Edge on Windows")
  assert.equal(browserDeviceName(""), "Browser")
})

test("Your devices rows: pairing's name where it gave one, else role and address end", () => {
  const h1 = "11".repeat(32), h2 = "22".repeat(32)
  const devices = [{ hex: h1, npub: npubEncode(h1), role: "Mesh vault" }, { hex: h2, npub: npubEncode(h2), role: "Paired vault" }]
  const rows = deviceRows(devices, [{ hex: h2, name: "Logen's iPhone", role: "phone" }])
  assert.equal(rows[0].title, `Mesh vault ${npubEncode(h1).slice(0, 9)}…${npubEncode(h1).slice(-4)}`)
  assert.equal(rows[1].title, "Logen's iPhone")
  assert.equal(rows[1].kind, "Phone")
})
