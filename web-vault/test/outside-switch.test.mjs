// "Show 'Outside your web' under posts" (outside-switch.js, default on) and the zap folding of call 4: an outside
// zap keeps its amount, its words and face go.
import test from "node:test"
import assert from "node:assert/strict"
import { showsOutside, setShowsOutside, onShowsOutside, foldedZap, zapWords } from "../src/net/outside-switch.js"

const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("the switch is on by default, kept, and tells its listeners", () => {
  const s = store()
  assert.equal(showsOutside(s), true)
  let heard = 0
  const off = onShowsOutside(() => heard++)
  setShowsOutside(false, s)
  assert.equal(showsOutside(s), false)
  setShowsOutside(true, s)
  assert.equal(showsOutside(s), true)
  off()
  setShowsOutside(false, s)
  assert.equal(heard, 2)
})

test("foldedZap: the amount stays, the words and the sender go", () => {
  const row = { id: "z", who: "a".repeat(64), text: "claim your airdrop", comment: "x", sats: 2100, zap: true }
  assert.deepEqual(foldedZap(row), { id: "z", who: null, text: "", comment: "", sats: 2100, zap: true })
})

test("zapWords: only outside zaps lose their words; other rows are untouched", () => {
  const IN = "1".repeat(64), OUT = "2".repeat(64)
  const rows = [
    { id: 1, type: "zap", who: [IN], comment: "gm", sats: 21 },
    { id: 2, type: "zap", who: [OUT], comment: "spam", sats: 5 },
    { id: 3, type: "reply", who: [OUT], comment: "" },
  ]
  const out = zapWords(rows, pk => pk === IN)
  assert.equal(out[0].comment, "gm")
  assert.equal(out[1].comment, ""); assert.equal(out[1].sats, 5); assert.deepEqual(out[1].who, [OUT])
  assert.equal(out[2], rows[2])
})
