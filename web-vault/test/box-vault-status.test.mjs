// The box's Trust ranking card words (src/box/vault-status.js): the same cases as the apps' VaultStatusTests
// (HavenApp MediaLogic) and VaultStatusTest (Android), so all three say the same thing.
import test from "node:test"
import assert from "node:assert/strict"
import * as T from "../src/box/vault-status.js"
import { mockVaultStatus } from "../src/box/mock.js"

const me = "a".repeat(64)
const buckets = at => Array.from({ length: 101 }, (_, s) => at[s] ?? 0)

test("a running pass says its ring and lists", () => {
  const s = { version: 1, state: "running", accounts: [{ account: me, running: true, ring: 3, ringDone: 412, ringTotal: 1980, listsRead: 37, finishedAt: 0, handoffs: [] }] }
  assert.equal(T.headline(s), "Ranking your web")
  const a = T.accountOf(s, me)
  assert.equal(T.progress(a), "Ring 3 · 412 of 1,980 lists · 37 read this run")
  assert.equal(T.finished(a, 1000), "No ranking yet")
  assert.equal(T.pausedHint(s), null)
})

test("paused says why and keeps its place", () => {
  const s = { version: 1, state: "paused", pausedWhy: "app", accounts: [{ account: me, ring: 2, ringDone: 50, cut: true, finishedAt: 0, handoffs: [] }] }
  assert.equal(T.headline(s), "Paused while the window is open")
  assert.ok(T.pausedHint(s))
  assert.equal(T.progress(s.accounts[0]), "Ring 2 · 50 lists read · waiting to go on")
  const busy = { ...s, pausedWhy: "busy" }
  assert.equal(T.headline(busy), "Paused while an import or copy runs")
  assert.equal(T.pausedHint(busy), null)
})

test("a finished pass counts distant connections at the bar, and names the devices", () => {
  const b = "b".repeat(64), c = "c".repeat(64)
  const a = T.accountOf({ accounts: [{ account: me, finishedAt: 2800,
    result: { builtAt: 2800, people: 78855, viewBar: 55, distantByShown: buckets({ 54: 5, 55: 3, 80: 2 }) },
    distantFetchAt: 9280, distantFetchPeople: 500, distantFetchNew: 34,
    handoffs: [{ device: b, role: "phone", name: "12 mini", tookAt: 6400 }, { device: c, checkedAt: 9900 }] }] }, "unknown")
  assert.equal(T.progress(a), null)
  assert.equal(T.finished(a, 10000), "Finished 2 h ago · 78,855 people ranked")
  assert.equal(T.distant(a), "5 distant connections at your bar (55)")
  assert.equal(T.distant(a, 54), "10 distant connections at your bar (54)")
  assert.equal(T.distant(a, 81), "0 distant connections at your bar (81)")
  assert.equal(T.distantFetch(a, 10000), "Distant posts fetched 12 min ago · 34 new from 500 people")
  assert.equal(T.handoff(a.handoffs[0], 10000), "Took it 1 h ago")
  assert.equal(T.handoff(a.handoffs[1], 10000), "Hasn't taken the ranking yet")
  assert.equal(T.handoffName(a.handoffs[0], new Map([[b, "Moto"]])), "12 mini", "the engine's name first")
  assert.equal(T.handoffName({ ...a.handoffs[0], name: " " }, new Map([[b, "Moto"]])), "Moto", "then the box's devices list")
  assert.equal(T.handoffName({ ...a.handoffs[0], name: "" }, new Map()), "Phone", "the type only when no name")
  assert.equal(T.handoffName(a.handoffs[1], new Map()), "A paired device")
})

test("off, ago, updated, and the mock", () => {
  assert.equal(T.headline({ state: "off", accounts: [] }), "Trust ranking is off here")
  assert.equal(T.accountOf({ accounts: [] }, me), null)
  assert.equal(T.ago(199_990, 200_000), "just now")
  assert.equal(T.ago(200_000 - 86_400, 200_000), "1 day ago")
  assert.equal(T.ago(300_000, 200_000), "just now")
  assert.equal(T.updated(940, 1000), "Updated 1 min ago")
  assert.equal(T.updated(0, 1000), null)
  const m = mockVaultStatus(100_000)
  assert.equal(T.headline(m), "Ranking your web")
  assert.equal(T.distant(m.accounts[0]), "1,840 distant connections at your bar (55)", "the mock's distantAtBar matches its buckets")
})
