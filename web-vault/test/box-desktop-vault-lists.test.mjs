// Desktop Vaults in the public lists (src/box/desktop-vault-lists.js) against docs/fixtures/desktop-vaults/lists.json,
// the cases Apple DesktopVaultsTests and Android DesktopVaultsRules read too. Nothing is signed or sent.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import * as L from "../src/box/desktop-vault-lists.js"

const doc = JSON.parse(readFileSync(new URL("../../docs/fixtures/desktop-vaults/lists.json", import.meta.url), "utf8"))
const named = doc.vaults
const vaults = Object.values(named)
const keyOf = v => (v ? Object.keys(named).find(k => named[k].id === v.id) ?? null : null)
const expected = e => (e.refused ? { refused: e.refused } : { tags: e.tags })

test("the fixture has the cases the apps run", () => {
  assert.ok(doc.cases.length > 40)
  assert.deepEqual([...new Set(doc.cases.map(c => c.op))].sort(), ["hostTaken", "off", "on", "overGuidance", "owner", "remove", "reorder"])
})

for (const c of doc.cases) {
  test(`${c.op}: ${c.name}`, () => {
    const vault = c.vault ? named[c.vault] : null
    switch (c.op) {
      case "owner":
        return assert.equal(keyOf(L.owner(c.tag, c.list, vaults)), c.expect.owner ?? null)
      case "on":
      case "off": {
        const r = c.op === "on" ? L.turningOn(vault, c.path, c.list, c.tags, vaults) : L.turningOff(vault, c.path, c.list, c.tags)
        assert.deepEqual(r, expected(c.expect))
        if (c.op === "on" && r.tags && r.tags !== c.tags) assert.ok(L.isListed(vault, c.path, c.list, r.tags))
        return
      }
      case "remove": {
        const r = L.removingVault(vault, c.lists)
        if (c.expect.refused) return assert.deepEqual(r, { refused: c.expect.refused })
        return assert.deepEqual(r, { changed: c.expect.changed })
      }
      case "reorder":
        return assert.deepEqual(L.reordered(c.tags, c.list, vaults), c.expect.tags)
      case "overGuidance":
        return assert.equal(L.overGuidance(c.tags, c.list), c.expect.over)
      case "hostTaken":
        return assert.equal(keyOf(L.hostTaken(c.url, vaults, c.except ? named[c.except].id : null)), c.expect.owner ?? null)
      default:
        assert.fail(`unknown op ${c.op}`)
    }
  })
}

test("a switch adds the Vault's whole base, path included (Tron S2)", () => {
  const v = { id: "h", name: "", httpsURL: "https://mac.example.com/haven", order: 0 }
  assert.deepEqual(L.entry(v, "web", 10002), ["r", "wss://mac.example.com/haven"])
  assert.deepEqual(L.entry(v, "web", 10050), ["relay", "wss://mac.example.com/haven/inbox"])
  assert.deepEqual(L.entry(v, "web", 10063), ["server", "https://mac.example.com/haven"])
  assert.ok(L.isListed(v, "web", 10002, [["r", "wss://mac.example.com/haven"]]))
  assert.equal(L.entry(v, "mesh", 10002), null)
  assert.equal(L.refusal(10050), "Add another DM inbox relay first.")
  assert.equal(L.displayName(v), "mac.example.com")
})
