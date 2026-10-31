// Compose closes back to the page it came from only when that page is this app's (src/components/nav-depth.js).
import test from "node:test"
import assert from "node:assert/strict"
import { startNavDepth, canGoBack } from "../src/components/nav-depth.js"

// A history with hash entries: go(hash) adds one (state null, as a link does), back() returns to the previous one.
function fakeWindow(start = null) {
  const entries = [{ state: start }]
  let i = 0, onHash = null
  const win = {
    history: {
      get state() { return entries[i].state },
      replaceState(state) { entries[i] = { state } },
      back() { if (i > 0) { i--; onHash?.() } },
    },
    addEventListener: (_, fn) => { onHash = fn },
    removeEventListener: () => { onHash = null },
    go() { entries.splice(i + 1); entries.push({ state: null }); i++; onHash?.() },
  }
  return win
}

test("the first page can't go back; each new page can; Back lands on an entry that knows its depth", () => {
  const win = fakeWindow()
  startNavDepth(win)
  assert.equal(canGoBack(win), false, "opened straight at #/compose")
  win.go()
  assert.equal(canGoBack(win), true)
  win.go()
  assert.equal(win.history.state.nvDepth, 2)
  win.history.back()
  assert.equal(win.history.state.nvDepth, 1)
  win.go()
  assert.equal(win.history.state.nvDepth, 2, "counts on from where Back left it")
  win.history.back(); win.history.back()
  assert.equal(canGoBack(win), false)
})

test("a reload keeps the depth already on the entry, and other state on it survives", () => {
  const win = fakeWindow({ nvDepth: 3, nvSheet: true })
  startNavDepth(win)
  assert.equal(win.history.state.nvDepth, 3)
  assert.equal(win.history.state.nvSheet, true)
  win.go()
  assert.equal(win.history.state.nvDepth, 4)
})

test("no history state at all reads as the first page", () => {
  assert.equal(canGoBack({ history: { state: null } }), false)
  assert.equal(canGoBack({}), false)
})
