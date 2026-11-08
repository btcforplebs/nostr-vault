// The /relay/ page rejoins the mesh by itself: at load when vaults are saved (a reload, crash or tab discard),
// and on resume/pageshow/visible, unless the person at the page pressed Stop mesh. The web app's Relay screen doesn't.
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { mountFipsPanel, MESH_OFF_ITEM } from "../src/fips/panel.js"

let els, store, starts, logs, win
const el = () => ({ value: "", textContent: "", onclick: null })
const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) }
const fakeWin = () => {
  const on = {}, docOn = {}
  const document = { visibilityState: "visible", addEventListener: (t, f) => (docOn[t] ??= []).push(f) }
  return { document, addEventListener: (t, f) => (on[t] ??= []).push(f), fire: t => (on[t] ?? []).forEach(f => f({})), fireDoc: t => (docOn[t] ?? []).forEach(f => f({})) }
}
const startRelay = async () => {
  const r = { status: { npub: "npub1test" }, stopped: false, stop: async () => { r.stopped = true } }
  starts.push(r)
  return r
}
const owners = new Set(["a".repeat(64)])
const mount = (opts = {}) => mountFipsPanel({ haven: {}, owners, log: (t, d) => logs.push(t), storage, autoStart: true, win, startRelay, ...opts })
const tick = () => new Promise(r => setTimeout(r, 0))

beforeEach(() => {
  els = new Map(["fipsOwners", "fipsSave", "fipsStart", "fipsStatus", "sfips"].map(id => [id, el()]))
  globalThis.document = { getElementById: id => els.get(id) ?? null }
  store = new Map(); starts = []; logs = []; win = fakeWin()
})

test("a page load with saved vaults joins the mesh without a click", async () => {
  mount()
  await tick()
  assert.equal(starts.length, 1)
  assert.equal(els.get("fipsStart").textContent, "Stop mesh")
  assert.ok(logs.includes("fips-autostart"))
})

test("no vaults saved or no Haven: nothing to join", async () => {
  mount({ owners: new Set() })
  mount({ haven: undefined })
  await tick()
  assert.equal(starts.length, 0)
})

test("after Stop mesh it stays off across reloads and resumes, until Start mesh", async () => {
  mount()
  await tick()
  await els.get("fipsStart").onclick()
  assert.equal(starts[0].stopped, true)
  assert.equal(store.get(MESH_OFF_ITEM), "1")
  win.fire("pageshow"); win.fireDoc("resume"); await tick()
  assert.equal(starts.length, 1, "no rejoin after Stop")
  // reload
  win = fakeWin(); mount(); await tick()
  assert.equal(starts.length, 1, "a reload keeps it off")
  await els.get("fipsStart").onclick()
  assert.equal(starts.length, 2)
  assert.equal(store.has(MESH_OFF_ITEM), false)
})

test("resume, pageshow and turning visible rejoin when the mesh is down; never a second node", async () => {
  let fail = true
  mount({ startRelay: async (...a) => { if (fail) throw new Error("offline"); return startRelay(...a) } })
  await tick()
  assert.equal(starts.length, 0)
  assert.ok(logs.includes("fips-error"))
  fail = false
  win.fireDoc("resume"); win.fire("pageshow"); win.fireDoc("visibilitychange")
  await tick()
  assert.equal(starts.length, 1, "three events while starting = one start")
  win.fire("pageshow"); await tick()
  assert.equal(starts.length, 1, "already up: left alone")
})

test("a hidden tab doesn't rejoin on visibilitychange", async () => {
  store.set(MESH_OFF_ITEM, "0")
  mount({ startRelay: async () => { throw new Error("offline") } })
  await tick()
  const before = logs.filter(t => t === "fips-error").length
  win.document.visibilityState = "hidden"
  win.fireDoc("visibilitychange"); await tick()
  assert.equal(logs.filter(t => t === "fips-error").length, before)
})

test("the web app's Relay screen (no autoStart) still waits for the click and writes no off flag", async () => {
  mount({ autoStart: false })
  win.fire("pageshow"); win.fireDoc("resume"); await tick()
  assert.equal(starts.length, 0)
  await els.get("fipsStart").onclick()
  assert.equal(starts.length, 1)
  await els.get("fipsStart").onclick()
  assert.equal(store.has(MESH_OFF_ITEM), false)
})
