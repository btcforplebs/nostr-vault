// The site shell (website/shell.js) on a phone opens the web app as /vault/ itself, not in its full-screen frame, so
// the page that scrolls is the app's and Safari's toolbar can shrink. Desktop and iPad keep the frame.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../website/shell.js", import.meta.url), "utf8")

/** Runs shell.js on a fake page at `hash`, `phone` or not; returns what it did. */
function run({ hash = "", phone = false } = {}) {
  const did = { replaced: null, assigned: null, framed: false }
  const listeners = {}
  const el = () => ({ classList: { add() {}, remove() {} }, style: {}, append() { did.framed = true }, setAttribute() {}, removeAttribute() {},
    addEventListener() {}, getBoundingClientRect: () => ({ top: 0, left: 0, width: 300, height: 600 }), focus() {} })
  const frame = { ...el(), contentWindow: { location: { hash: "#/thread/" + "a".repeat(64) }, addEventListener() {} } }
  const document = {
    documentElement: el(), body: el(),
    querySelector: s => s === ".phone-slot" ? el() : null,
    querySelectorAll: () => [],
    getElementById: id => id === "site" ? el() : null,
    createElement: t => t === "iframe" ? frame : el(),
    addEventListener() {}, fonts: { ready: { then() {} } },
  }
  const location = { pathname: "/", search: "", hash, replace: u => { did.replaced = u }, assign: u => { did.assigned = u } }
  const window = {
    document, location, innerWidth: phone ? 390 : 1280, innerHeight: 844, scrollX: 0, scrollY: 0,
    matchMedia: q => ({ matches: q.includes("pointer: coarse") ? phone : false }),
    addEventListener: (k, f) => { listeners[k] = f }, requestAnimationFrame() {}, scrollTo() {},
    history: { replaceState() {} },
  }
  window.window = window; window.top = window; window.parent = window
  vm.runInNewContext(source, { ...window, window, ResizeObserver: class { observe() {} } })
  return { did, window, listeners, location }
}

test("a phone opening nostrvault.app goes to /vault/, replaced, not framed", () => {
  const { did } = run({ phone: true })
  assert.equal(did.replaced, "/vault/")
  assert.equal(did.framed, false)
})

test("a phone keeps a deep link's app address, so a refresh reopens the same screen", () => {
  const id = "b".repeat(64)
  assert.equal(run({ phone: true, hash: `#/thread/${id}` }).did.replaced, `/vault/#/thread/${id}`)
})

test("a phone on a marketing section stays on the page, and Open the app goes to the app's address as a new entry", () => {
  const { did, window } = run({ phone: true, hash: "#features" })
  assert.equal(did.replaced, null)
  assert.equal(did.framed, true) // the app still runs in the hero's phone
  window.nvShell.open()
  assert.equal(did.assigned, "/vault/#/thread/" + "a".repeat(64))
})

test("a phone typing an app address on the marketing page goes to the app", () => {
  const { did, listeners, location } = run({ phone: true, hash: "#about" })
  location.hash = "#/feed"
  listeners.hashchange()
  assert.equal(did.replaced, "/vault/#/feed")
})

test("desktop keeps the frame", () => {
  const { did } = run({ phone: false })
  assert.equal(did.replaced, null)
  assert.equal(did.framed, true)
})
