// Box › My Devices › Add a device (src/box/pair-device.js): what the screen shows for each state the box reports, and
// that the words and lines are the shared pairing ones. Nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { pairView, refusalLine, secondsLeft, wordsOf } from "../src/box/pair-device.js"
import { refusalText } from "../src/net/mesh-pairing.js"

const fx = JSON.parse(readFileSync(new URL("../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing/checkwords-cases.json", import.meta.url), "utf8"))
const WORDS = readFileSync(new URL("../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing/words.txt", import.meta.url), "utf8").split("\n").filter(Boolean)
const box = { npub: "npub1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz9" }
const device = { npub: "npub1wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww", name: "Logen's iPhone", role: "phone" }

test("the box's word indexes read as the fixture's words", () => {
  for (const c of fx.cases) {
    const idx = c.words.map(w => WORDS.indexOf(w))
    assert.deepEqual(wordsOf(idx), c.words)
  }
  assert.equal(wordsOf([1, 2, 3]), null)
  assert.equal(wordsOf([1, 2, 3, 2048]), null)
  assert.equal(wordsOf(null), null)
})

test("idle, waiting, hello, linked, failed and busy", () => {
  const now = 1_793_800_000_000
  assert.equal(pairView(null).step, "idle")
  assert.ok(pairView({ state: "idle" }).canStart)

  const w = pairView({ state: "waiting", code: "nvpair:v1?m=x", expiresAt: 1_793_800_120, box }, now)
  assert.equal(w.step, "waiting")
  assert.equal(w.code, "nvpair:v1?m=x")
  assert.equal(w.secondsLeft, 120)
  assert.ok(w.canCancel && !w.canStart)

  const h = pairView({ state: "hello", device, words: [172, 696, 1627, 1557], confirmText: "Add Logen's iPhone as another of your phones.", expiresAt: 1_793_800_030, box, refusal: "otherOwner" }, now)
  assert.equal(h.step, "hello")
  assert.equal(h.title, "Logen's iPhone wants to pair")
  assert.deepEqual(h.words, [WORDS[172], WORDS[696], WORDS[1627], WORDS[1557]])
  assert.equal(h.role, "phone")
  assert.equal(h.roleWord, "phone")
  assert.equal(h.confirmText, "Add Logen's iPhone as another of your phones.")
  assert.match(h.text, /npub1zzz…zzz9/)
  assert.equal(h.secondsLeft, 30)
  assert.equal(h.refusal, refusalText("otherOwner"), "a stranger's hello shows the shared line and the code stays")

  const l = pairView({ state: "linked", device, acked: 2 })
  assert.equal(l.step, "linked")
  assert.match(l.title, /Linked Logen's iPhone/)
  assert.ok(l.canStart)
  // Stored but no relay took the ack: a failure with the way out, never "Linked".
  const noAck = pairView({ state: "linked", device, acked: 0, error: "no relay took the answer to the phone; remove the device and pair again" })
  assert.equal(noAck.step, "failed")
  assert.match(noAck.text, /remove the device and pair again/)

  assert.equal(pairView({ state: "expired" }).title, refusalText("expired"))
  assert.equal(pairView({ state: "aborted" }).text, "Start again, and only show your code to your own device.")
  const b = pairView({ state: "busy" })
  assert.equal(b.step, "busy")
  assert.ok(!b.canStart && !b.canCancel)
})

test("refusal words read as on the phone", () => {
  assert.equal(refusalLine("otherOwner"), refusalText("otherOwner"))
  assert.equal(refusalLine("refuseOtherRole", { otherRole: "mac" }), refusalText("refuseOtherRole", { role: "mac" }))
  assert.match(refusalLine("switchTo"), /Sign in to the box as that account/)
  assert.equal(refusalLine("abort"), refusalText("abort"))
  assert.equal(refusalLine(""), null)
  assert.equal(secondsLeft(100, 50_000), 50)
  assert.equal(secondsLeft(100, 200_000), 0)
})
