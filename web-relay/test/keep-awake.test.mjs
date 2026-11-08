// The screensaver's wake lock comes back after a reload, and storage persistence is asked for only when not granted.
import { test } from "node:test"
import assert from "node:assert/strict"
import { createKeepAwake, ensurePersisted, SAVER_ITEM } from "../src/keep-awake.js"

const mkStorage = (init = {}) => { const m = new Map(Object.entries(init)); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const mkLock = () => {
  let requests = 0
  const held = []
  return {
    get requests() { return requests }, held,
    async request(type) {
      assert.equal(type, "screen"); requests++
      const ls = []
      const l = { released: false, addEventListener: (t, f) => ls.push(f), release: async () => { l.released = true; ls.forEach(f => f()) } }
      held.push(l)
      return l
    },
  }
}
const mkDoc = () => { const fs = []; return { visibilityState: "visible", addEventListener: (t, f) => t === "visibilitychange" && fs.push(f), fire: () => fs.forEach(f => f()) } }

test("a reload with the screensaver on takes the wake lock again without a click", async () => {
  const wakeLock = mkLock(), seen = []
  const a = createKeepAwake({ storage: mkStorage({ [SAVER_ITEM]: "1" }), wakeLock, doc: mkDoc(), onChange: s => seen.push(s) })
  await a.restore()
  assert.equal(wakeLock.requests, 1)
  assert.equal(a.held, true)
  assert.deepEqual(seen.at(-1), { saverOn: true, held: true })
})

test("off, or never turned on: restore takes nothing", async () => {
  for (const init of [{}, { [SAVER_ITEM]: "0" }]) {
    const wakeLock = mkLock()
    const a = createKeepAwake({ storage: mkStorage(init), wakeLock, doc: mkDoc() })
    await a.restore()
    assert.equal(wakeLock.requests, 0)
    assert.equal(a.saverOn, false)
  }
})

test("start and stop are kept for the next load; a lock the browser dropped is re-taken when visible", async () => {
  const storage = mkStorage(), wakeLock = mkLock(), doc = mkDoc()
  const a = createKeepAwake({ storage, wakeLock, doc })
  await a.start()
  assert.equal(storage.m.get(SAVER_ITEM), "1")
  await wakeLock.held[0].release() // the browser drops it when the tab hides
  assert.equal(a.held, false)
  doc.fire(); await new Promise(r => setTimeout(r, 0))
  assert.equal(wakeLock.requests, 2)
  assert.equal(a.held, true)
  await a.stop()
  assert.equal(storage.m.get(SAVER_ITEM), "0")
  assert.equal(wakeLock.held[1].released, true)
  doc.fire(); await new Promise(r => setTimeout(r, 0))
  assert.equal(wakeLock.requests, 2, "stopped: not re-taken")
})

test("a failed request (tab hidden at load) is retried when the page turns visible", async () => {
  let fail = true
  const inner = mkLock()
  const wakeLock = { request: t => (fail ? Promise.reject(new Error("NotAllowedError")) : inner.request(t)) }
  const doc = mkDoc()
  const a = createKeepAwake({ storage: mkStorage({ [SAVER_ITEM]: "1" }), wakeLock, doc })
  await a.restore()
  assert.equal(a.held, false)
  fail = false
  doc.fire(); await new Promise(r => setTimeout(r, 0))
  assert.equal(a.held, true)
})

test("persist is asked only when storage isn't persisted yet", async () => {
  let asked = 0
  assert.equal(await ensurePersisted({ persisted: async () => true, persist: async () => (asked++, true) }), true)
  assert.equal(asked, 0)
  assert.equal(await ensurePersisted({ persisted: async () => false, persist: async () => (asked++, true) }), true)
  assert.equal(asked, 1)
  assert.equal(await ensurePersisted(undefined), false)
  assert.equal(await ensurePersisted({ persisted: async () => { throw new Error("x") }, persist: async () => true }), false)
})
