// "Update ready, tap to reload": a new build's service worker waits beside the one serving open pages until a page
// asks (public/sw.js), and the page shows the bar once one waits (src/sw-update.js).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const SW = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8")

// sw.js in a worker-like global with an empty network; counts skipWaiting calls.
function worker({ active }) {
  const listeners = {}, skipped = []
  const self = {
    registration: { active }, skipWaiting: async () => { skipped.push(1) }, clients: { claim: async () => {} },
    addEventListener: (t, f) => (listeners[t] = f),
  }
  const fetch = async () => new Response("", { status: 200, headers: { "Content-Type": "text/html" } })
  const caches = { open: async () => ({ put: async () => {}, match: async () => undefined, keys: async () => [] }), keys: async () => [], delete: async () => true, match: async () => undefined }
  const ctx = { self, caches, fetch, location: new URL("https://vault.example/vault/sw.js"), Request, Response, URL, console }
  ctx.globalThis = ctx
  vm.runInNewContext(SW, ctx)
  const install = () => { const w = []; listeners.install({ waitUntil: p => w.push(p) }); return Promise.all(w) }
  return { install, message: data => listeners.message({ data }), skipped }
}

test("a first install starts at once; a new build waits until a page says skip-waiting", async () => {
  const first = worker({ active: null })
  await first.install()
  assert.equal(first.skipped.length, 1, "no worker serves pages yet, so the first one starts")

  const next = worker({ active: {} })
  await next.install()
  assert.equal(next.skipped.length, 0, "a new build waits beside the worker serving open pages")
  next.message("something else")
  assert.equal(next.skipped.length, 0)
  next.message("skip-waiting")
  assert.equal(next.skipped.length, 1, "the bar's tap starts it")
})

// A fake registration + navigator.serviceWorker + page.
function page({ controller = true, waiting = null } = {}) {
  const on = (o) => { o.l = {}; o.addEventListener = (t, f) => ((o.l[t] ||= []).push(f)); o.emit = t => (o.l[t] || []).forEach(f => f()); return o }
  const posted = []
  const mk = state => on({ state, postMessage: m => posted.push(m) })
  const reg = on({ waiting: waiting && mk("installed"), installing: null, updates: 0, update: async () => { reg.updates++ } })
  const sw = on({ controller: controller ? {} : null })
  const doc = on({ visibilityState: "visible" })
  let reloads = 0, now = 0
  const timers = []
  const env = { reload: () => reloads++, doc, every: () => {}, after: f => timers.push(f), now: () => now }
  return {
    reg, sw, env, posted, timers, get reloads() { return reloads }, tick: ms => (now += ms),
    install() { const w = mk("installing"); reg.installing = w; reg.emit("updatefound"); w.state = "installed"; reg.waiting = w; reg.installing = null; w.emit("statechange") },
  }
}

// sw-update.js keeps one bar state per page, so each case gets a fresh copy of the module.
let n = 0
const fresh = () => import(`../src/sw-update.js?case=${n++}`)

test("a build that finishes installing while the page runs shows the bar; a tap starts it and reloads", async () => {
  const m = await fresh(), p = page()
  const seen = []
  m.onUpdateReady(r => seen.push(r))
  m.watchUpdates(p.reg, p.sw, p.env)
  assert.deepEqual(seen, [false])
  p.install()
  assert.deepEqual(seen, [false, true], "the bar shows once the new worker waits")
  m.applyUpdate()
  assert.deepEqual(p.posted, ["skip-waiting"])
  assert.equal(p.reloads, 0, "waits for the new worker to take over")
  p.sw.emit("controllerchange")
  assert.equal(p.reloads, 1, "reloads onto the new build")
})

test("a worker that never takes over still gets the page reloaded", async () => {
  const m = await fresh(), p = page()
  m.watchUpdates(p.reg, p.sw, p.env)
  p.install()
  m.applyUpdate()
  assert.equal(p.timers.length, 1)
  p.timers[0]()
  assert.equal(p.reloads, 1)
})

test("the first install (no controller yet) shows no bar", async () => {
  const m = await fresh(), p = page({ controller: false })
  const seen = []
  m.onUpdateReady(r => seen.push(r))
  m.watchUpdates(p.reg, p.sw, p.env)
  p.install()
  p.sw.emit("controllerchange")
  assert.deepEqual(seen, [false])
  assert.equal(p.reloads, 0)
})

test("a worker already waiting at load is started quietly: this page is the new build", async () => {
  const m = await fresh(), p = page({ waiting: true })
  const seen = []
  m.onUpdateReady(r => seen.push(r))
  m.watchUpdates(p.reg, p.sw, p.env)
  assert.deepEqual(p.posted, ["skip-waiting"])
  assert.deepEqual(seen, [false], "no bar")
})

test("another tab's tap takes over this page: this page shows the bar, and its tap just reloads", async () => {
  const m = await fresh(), p = page()
  const seen = []
  m.onUpdateReady(r => seen.push(r))
  m.watchUpdates(p.reg, p.sw, p.env)
  p.sw.emit("controllerchange")
  assert.deepEqual(seen, [false, true])
  p.reg.waiting = null
  m.applyUpdate()
  assert.deepEqual(p.posted, [])
  assert.equal(p.reloads, 1)
})

test("a tab coming back into view asks for a new build at most every 30 minutes", async () => {
  const m = await fresh(), p = page()
  m.watchUpdates(p.reg, p.sw, p.env)
  p.env.doc.emit("visibilitychange")
  assert.equal(p.reg.updates, 0)
  p.tick(30 * 60_000)
  p.env.doc.emit("visibilitychange")
  assert.equal(p.reg.updates, 1)
  p.env.doc.emit("visibilitychange")
  assert.equal(p.reg.updates, 1)
})

// The page's own timers, as a browser has them: setInterval and setTimeout throw "Illegal invocation" when called as a
// method of anything but the window. Every case above passes its own env, so the default one is checked here.
test("with no env given, the page's timers are called as functions, not as methods of env (Illegal invocation)", async () => {
  const m = await fresh(), p = page()
  const saved = { setInterval: globalThis.setInterval, setTimeout: globalThis.setTimeout, document: globalThis.document, location: globalThis.location }
  const intervals = [], timeouts = []
  const strict = list => function (f, ms) { if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation"); list.push([f, ms]); return list.length }
  globalThis.setInterval = strict(intervals)
  globalThis.setTimeout = strict(timeouts)
  globalThis.document = p.env.doc
  globalThis.location = { reload: () => {} }
  try {
    assert.doesNotThrow(() => m.watchUpdates(p.reg, p.sw))
    assert.equal(intervals.length, 1, "the half-hourly check is scheduled")
    assert.equal(intervals[0][1], 30 * 60_000)
    assert.equal(p.env.doc.l.visibilitychange?.length, 1, "and the check on coming back to the tab")
    p.install()
    assert.doesNotThrow(() => m.applyUpdate())
    assert.equal(timeouts.length, 1, "the fallback reload is scheduled")
  } finally { Object.assign(globalThis, saved) }
})
