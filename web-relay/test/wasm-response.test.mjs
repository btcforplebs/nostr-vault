// haven.js wasmResponse: loadHaven takes the response web-vault's boot script (nv-preload.js) already started for the
// same URL, so the wasm downloads once in every engine (Safari's never reused a preload link: Tidy's audit 11-20, W5).
import test from "node:test"
import assert from "node:assert/strict"
import { wasmResponse } from "../src/haven/haven.js"

const URL_ = "https://nostrvault.app/vault/assets/haven-Ab12.wasm"
const page = early => ({ document: { baseURI: "https://nostrvault.app/vault/" }, ...(early ? { __nvHavenWasm: early } : {}) })
const counting = () => { const asked = []; return Object.assign(url => { asked.push(String(url)); return Promise.resolve({ ok: true, own: true }) }, { asked }) }

test("the early response for the same URL is used, once, and nothing is fetched again", async () => {
  const early = { ok: true, early: true }, g = page({ href: URL_, res: Promise.resolve(early) }), get = counting()
  assert.equal(await wasmResponse(new URL(URL_), g, get), early)
  assert.equal(get.asked.length, 0)
  assert.equal(g.__nvHavenWasm, undefined, "taken: a second load fetches its own")
  assert.equal((await wasmResponse(new URL(URL_), g, get)).own, true)
})

test("a relative URL resolves against the page before comparing", async () => {
  const early = { ok: true }, get = counting()
  assert.equal(await wasmResponse("/vault/assets/haven-Ab12.wasm", page({ href: URL_, res: early }), get), early)
})

test("no early response, another build's URL, a failed or refused early one: a fetch of its own", async () => {
  for (const [why, g] of [
    ["none (the box build)", page()],
    ["another URL", page({ href: "https://nostrvault.app/vault/assets/haven-Old.wasm", res: Promise.resolve({ ok: true }) })],
    ["failed", page({ href: URL_, res: Promise.resolve(null) })],
    ["refused", page({ href: URL_, res: Promise.resolve({ ok: false, status: 503 }) })],
    ["rejected", page({ href: URL_, res: Promise.reject(new Error("x")) })],
  ]) {
    const get = counting()
    assert.equal((await wasmResponse(new URL(URL_), g, get)).own, true, why)
    assert.equal(get.asked.length, 1, why)
  }
})
