// Coming back to the Vault tab (Logen 10-25): the tab is kept as it was left, as the phone keeps VaultTabView, and
// only what's new since then is asked of the relays. Fake fetchers: nothing reaches the network.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { keepVault, keptVault, sinceKept, fetchVault } from "../src/net/vault-lists.js"

const screen = readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")
const ME = "a".repeat(64), OTHER = "b".repeat(64)

test("a kept tab is per account and notes when it was left", () => {
  assert.equal(keptVault(OTHER), null)
  const before = Math.floor(Date.now() / 1000)
  keepVault(ME, { mode: "notes", filter: "mine", own: [{ id: "x" }], shown: 80, scrollY: 1200 })
  const k = keptVault(ME)
  assert.equal(k.mode, "notes"); assert.equal(k.filter, "mine"); assert.equal(k.shown, 80); assert.equal(k.scrollY, 1200)
  assert.ok(k.at >= before)
  assert.equal(keptVault(OTHER), null)
  assert.equal(sinceKept(k), k.at - 60)
  assert.equal(sinceKept(null), undefined)
})

test("fetchVault hands `since` to every fetcher, and nothing when there is none", async () => {
  const asked = {}
  const fetchers = {
    fetchInbound: async (v, me, r, o) => { asked.inbound = o.since; return [] },
    fetchFollowerLists: async (me, r, o) => { asked.lists = o.since; return [] },
    fetchGivenZaps: async (me, r, o) => { asked.given = o.since; return [] },
    fetchOwnExtras: async (v, me, r, o) => { asked.own = o.since; return 0 },
  }
  await fetchVault({}, ME, [], { fetchers, since: 1234 })
  assert.deepEqual(asked, { inbound: 1234, lists: 1234, given: 1234, own: 1234 })
  await fetchVault({}, ME, [], { fetchers })
  assert.deepEqual(asked, { inbound: undefined, lists: undefined, given: undefined, own: undefined })
})

test("the screen starts from the kept tab and only updates it", () => {
  assert.match(screen, /const \[k\] = useState\(\(\) => keptVault\(me\)\)/)
  assert.match(screen, /if \(!k\) \{ load\(\); return \}/)
  assert.match(screen, /update\(sinceKept\(k\)\)/)
  assert.match(screen, /useState\(!!k\)/) // no skeleton on the way back
  assert.match(screen, /keepVault\(who, \{ \.\.\.state, scrollY: scrolled\.current \}\)/)
  // A link to a mode still opens that mode.
  assert.match(screen, /link \?\? k\?\.mode \?\? "activity"/)
})
