// Reply opens with the keyboard up (src/screens/compose/keyboard.js): the tap focuses a hidden stand-in at once, and
// Compose's box takes the focus when it mounts, with the cursor at the end; the stand-in then goes.
import test, { mock } from "node:test"
import assert from "node:assert/strict"
import { primeKeyboard, takeKeyboard } from "../src/screens/compose/keyboard.js"

function fakeDoc() {
  const log = []
  const body = { kids: [], append(el) { this.kids.push(el); el.parent = this } }
  const doc = {
    body, log,
    createElement: tag => ({
      tag, style: {}, attrs: {}, setAttribute(k, v) { this.attrs[k] = v },
      focus(o) { log.push(["focus", tag, o]) },
      remove() { body.kids = body.kids.filter(k => k !== this); log.push(["remove", tag]) },
    }),
  }
  return doc
}

test("the tap focuses a hidden 16px field straight away, without scrolling", () => {
  const doc = fakeDoc()
  primeKeyboard(doc)
  assert.equal(doc.body.kids.length, 1)
  const [el] = doc.body.kids
  assert.equal(el.attrs["aria-hidden"], "true")
  assert.match(el.style.cssText, /font-size:16px/, "iOS zooms to a field under 16px")
  assert.match(el.style.cssText, /opacity:0/)
  assert.deepEqual(doc.log[0], ["focus", "input", { preventScroll: true }])
  takeKeyboard(null)
})

test("Compose's box takes the focus with the cursor at the end, then the stand-in goes", () => {
  const doc = fakeDoc()
  primeKeyboard(doc)
  const order = []
  const box = { value: "draft text", focus: () => order.push("box focus"), setSelectionRange: (a, b) => order.push(`caret ${a}-${b}`) }
  doc.log.length = 0
  takeKeyboard(box)
  assert.deepEqual(order, ["box focus", "caret 10-10"])
  assert.deepEqual(doc.log, [["remove", "input"]], "removed after the box has the focus, so the keyboard stays up")
  assert.equal(doc.body.kids.length, 0)
})

test("a second tap doesn't stack stand-ins; one Compose never takes is gone after 2 s", t => {
  mock.timers.enable({ apis: ["setTimeout"] })
  t.after(() => mock.timers.reset())
  const doc = fakeDoc()
  primeKeyboard(doc); primeKeyboard(doc)
  assert.equal(doc.body.kids.length, 1)
  mock.timers.tick(1999)
  assert.equal(doc.body.kids.length, 1)
  mock.timers.tick(2)
  assert.equal(doc.body.kids.length, 0)
})

test("nothing to do without a page", () => {
  primeKeyboard(undefined)
  takeKeyboard(null)
})
