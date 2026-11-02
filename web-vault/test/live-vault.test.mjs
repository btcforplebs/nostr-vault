// The Live Vault panel's rules (src/desktop/space/live-vault.js) and its fold key's sign-out wipe.
import test from "node:test"
import assert from "node:assert/strict"
import { snapshot, splitShown, topFaces, pillCount, rowText, readFolded, writeFolded, MAX_ROWS } from "../src/desktop/space/live-vault.js"
import { accountKeys } from "../src/haven/vault.js"

const line = (id, at, actors = ["a"]) => ({ id, created_at: at, actors })
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), key: i => [...m.keys()][i] ?? null, get length() { return m.size } } }

test("the rows on screen stay put: new lines wait for the pill", () => {
  const shown = snapshot([line("b", 20), line("a", 10)])
  assert.equal(shown.top, 20)
  const later = [line("c", 30, ["z"]), line("b", 25, ["a", "y"]), line("a", 10)]
  const { rows, held } = splitShown(later, shown)
  assert.deepEqual(rows.map(r => r.id), ["b", "a"]) // drawn order, not the new order
  assert.deepEqual(rows[0].actors, ["a", "y"]) // the line's latest form, in its old slot
  assert.deepEqual(held.map(r => r.id), ["c"])
})

test("older lines that come in late go below, not behind the pill", () => {
  const shown = snapshot([line("b", 20)])
  const { rows, held } = splitShown([line("b", 20), line("old", 5), line("new", 40)], shown)
  assert.deepEqual(rows.map(r => r.id), ["b", "old"])
  assert.deepEqual(held.map(r => r.id), ["new"])
})

test("nothing yet: the snapshot starts now, so only what arrives later waits", () => {
  const shown = snapshot([], 100)
  assert.deepEqual(shown, { ids: [], top: 100 })
  const { rows, held } = splitShown([line("n", 150), line("o", 50)], shown)
  assert.deepEqual(held.map(r => r.id), ["n"])
  assert.deepEqual(rows.map(r => r.id), ["o"])
})

test("a line that went away drops out; the snapshot is capped", () => {
  assert.deepEqual(splitShown([line("a", 1)], { ids: ["gone", "a"], top: 1 }).rows.map(r => r.id), ["a"])
  const many = Array.from({ length: MAX_ROWS + 5 }, (_, i) => line(`l${i}`, 100 - i))
  assert.equal(snapshot(many).ids.length, MAX_ROWS)
  assert.equal(splitShown(many, snapshot(many)).rows.length, MAX_ROWS)
})

test("faces on top: newest first, once each, the rest counted", () => {
  const ls = [line("1", 3, ["p", "q"]), line("2", 2, ["q", "r"]), line("3", 1, ["s", "t", "u", "v"])]
  assert.deepEqual(topFaces(ls, 3), { faces: ["p", "q", "r"], more: 4 })
  assert.deepEqual(topFaces([]), { faces: [], more: 0 })
})

test("the pill counts unread lines, else the ones held back", () => {
  assert.equal(pillCount(3, 1), 3)
  assert.equal(pillCount(0, 2), 2)
  assert.equal(pillCount(0, 0), 0)
})

test("row text: short @npub for people, note links left out", () => {
  assert.equal(rowText("hi nostr:npub1qqqqqqqqqqqqqqqqqqqq  see nostr:note1acd"), "hi @npub1qqqqqqq… see")
  assert.equal(rowText(), "")
})

test("fold state is per account and goes with the account's keys at sign-out", () => {
  const s = store(), me = "f".repeat(64), other = "e".repeat(64)
  assert.equal(readFolded(me, s), false)
  writeFolded(me, true, s)
  assert.equal(readFolded(me, s), true)
  assert.equal(readFolded(other, s), false)
  assert.ok(accountKeys(me, s).includes(`nv-space-folded:${me}`))
})
