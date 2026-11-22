// Your devices › sync rows on a box (src/box/sections/SyncRows.jsx, One Vault W3) over a pretend sync API: the first
// account sees each device with its copy state, Sync now and Copy from this vault; another signed-in account sees one
// Sync now for all; a 429 says how long to wait. Nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { fakeDom, tick, all, fire, button } from "./box-accounts-fake.mjs"

fakeDom()
const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { SyncRows, syncLine } = await vite.ssrLoadModule("/src/box/sections/SyncRows.jsx")
const { syncApi } = await vite.ssrLoadModule("/src/box/api-sync.js")
test.after(() => vite.close())

const dev = () => { const hex = getPublicKey(generateSecretKey()); return { hex, npub: npubEncode(hex) } }
const mac = dev(), phone = dev()
const now = Math.floor(Date.now() / 1000)

function fakeApi(report, { nowStatus = 202 } = {}) {
  const calls = []
  return {
    calls,
    state: async () => { calls.push(["state"]); return report },
    now: async d => { calls.push(["now", d]); if (nowStatus === 429) { const e = new Error("Asked just now. Try again in 42 s."); e.status = 429; throw e } return {} },
    first: async d => { calls.push(["first", d]); return {} },
  }
}
const account = state => ({ state, subscribe: () => () => {} })

async function mount(api, who) {
  const el = document.createElement("div")
  render(h(SyncRows, { ctx: {}, api, account: account(who), names: new Map([[mac.hex, "Logen's Mac"]]) }), el)
  for (let i = 0; i < 50 && !api.calls.length && who !== "watchOnly"; i++) await tick(5)
  await tick(30)
  return el
}

test("the first account sees each device: caught-up one gets Sync now, never-copied one gets Copy from this vault", async () => {
  const api = fakeApi({ busy: false, round: false, lastRound: now - 120, everySeconds: 900, devices: [
    { peer: mac.npub, token: true, syncedAt: now - 300, last: { kind: "sync", started: now - 300, finished: now - 290, files: 2 } },
    { peer: phone.npub, token: false, needs: "first_copy" },
  ] })
  const el = await mount(api, "first")
  const t = el.textContent
  assert.match(t, /Logen's Mac/)
  assert.match(t, /Caught up 5 min ago · 2 new files/)
  assert.match(t, /Not copied to this box yet/)
  fire(button(el, "Copy from this vault"), "click"); await tick(20)
  assert.deepEqual(api.calls.find(c => c[0] === "first"), ["first", phone.npub])
  assert.match(el.textContent, /That vault builds its copy first/)
  fire(button(el, "Sync now"), "click"); await tick(20)
  assert.deepEqual(api.calls.find(c => c[0] === "now"), ["now", mac.npub])
  render(null, el)
})

test("a joined account sees no devices, one Sync now for all, and the wait when throttled", async () => {
  const api = fakeApi({ busy: false, round: false, everySeconds: 900, devices: [] }, { nowStatus: 429 })
  const el = await mount(api, "signedIn")
  assert.equal(all(el).filter(n => n.localName === "button").length, 1)
  assert.doesNotMatch(el.textContent, /Copy from this vault/)
  fire(button(el, "Sync now"), "click"); await tick(20)
  assert.deepEqual(api.calls.find(c => c[0] === "now"), ["now", ""])
  assert.match(el.textContent, /Try again in 42 s/)
  render(null, el)
})

test("an account the box doesn't hold sees nothing and asks nothing", async () => {
  const api = fakeApi({ devices: [] })
  const el = await mount(api, "watchOnly")
  assert.equal(el.textContent, "")
  assert.equal(api.calls.length, 0)
})

test("row wording: running, unreachable, refused token", () => {
  assert.equal(syncLine({ peer: "p", token: true, last: { kind: "sync" } }, { running: "p" }), "Catching up now…")
  assert.match(syncLine({ peer: "p", token: true, reach: "nv-mesh: x" }), /Can't reach it right now/)
  assert.match(syncLine({ peer: "p", token: true, last: { error: "auth_refused" } }), /no longer accepts this box/)
})

test("syncApi turns a 429 into the wait", async () => {
  const signer = { signEvent: async t => ({ ...t, id: "0".repeat(64), pubkey: "0".repeat(64), sig: "0".repeat(128) }) }
  const api = syncApi({ signer, base: "http://box.test/api/box", fetchImpl: async () => new Response(JSON.stringify({ error: "x", retryAfter: 42 }), { status: 429 }) })
  await assert.rejects(api.now("npub1x"), e => e.status === 429 && /Try again in 42 s/.test(e.message))
})
