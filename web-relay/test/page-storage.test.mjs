// /relay/ and /vault/ share one origin, so one localStorage: each page's keys live under its own prefix.
import { test } from "node:test"
import assert from "node:assert/strict"
import { RELAY_NS, VAULT_NS, pageStorage, migrateRelayKeys } from "../src/page-storage.js"
import { loadOwners, saveOwners } from "../src/fips/owners.js"
import { loadRelayIdentity } from "../src/fips/node.js"

function memStorage() {
  const m = new Map()
  return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}

test("the relay page's old unprefixed keys move under its prefix once, and a moved key is never overwritten", () => {
  const s = memStorage()
  s.setItem("fips-relay-key", "a".repeat(64))
  s.setItem("fips-owners", "b".repeat(64))
  s.setItem("sk", "c".repeat(64))
  s.setItem("nv-device-sk", "vault's") // the vault's: not the relay's to take
  migrateRelayKeys(s)
  assert.deepEqual(Object.fromEntries(s.m), {
    "nv-relay:fips-relay-key": "a".repeat(64), "nv-relay:fips-owners": "b".repeat(64), "nv-relay:sk": "c".repeat(64), "nv-device-sk": "vault's",
  })
  // An old tab writing the unprefixed key again doesn't replace the moved one.
  s.setItem("fips-relay-key", "d".repeat(64))
  migrateRelayKeys(s)
  assert.equal(s.getItem("nv-relay:fips-relay-key"), "a".repeat(64))
  assert.equal(s.getItem("fips-relay-key"), null)
})

test("each page's FIPS key and paired vaults are its own", async () => {
  const s = memStorage()
  const relay = pageStorage(s, RELAY_NS), vault = pageStorage(s, VAULT_NS)
  saveOwners(new Set(["1".repeat(64)]), relay)
  const relayId = await loadRelayIdentity(relay), vaultId = await loadRelayIdentity(vault)
  assert.notDeepEqual(relayId.xOnlyPubkey, vaultId.xOnlyPubkey)
  assert.deepEqual((await loadRelayIdentity(relay)).xOnlyPubkey, relayId.xOnlyPubkey, "kept, not remade")
  assert.deepEqual([...loadOwners({ storage: relay, hash: "" })], ["1".repeat(64)])
  assert.deepEqual([...loadOwners({ storage: vault, hash: "" })], [])
  assert.deepEqual([...s.m.keys()].sort(), ["nv-relay:fips-owners", "nv-relay:fips-relay-key", "nv-vault:fips-relay-key"])
})

test("the FIPS code needs the page's storage: it never falls back to the shared localStorage", async () => {
  globalThis.localStorage = memStorage()
  try {
    assert.throws(() => loadOwners({ hash: "" }), TypeError)
    assert.throws(() => saveOwners(new Set()), TypeError)
    await assert.rejects(loadRelayIdentity(), TypeError)
    assert.equal(globalThis.localStorage.m.size, 0)
  } finally {
    delete globalThis.localStorage
  }
})
