// Pairing links: a #owner= fragment only adds owners, and only after the person at the browser confirms.
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { loadOwners } from "../src/fips/owners.js"

const key = () => getPublicKey(generateSecretKey())
let store, prompts
const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
const at = hash => {
  globalThis.location = { hash, pathname: "/relay/" }
  globalThis.history = { replaceState: (_s, _t, url) => (globalThis.location = { hash: "", pathname: url }) }
}
const load = answer => loadOwners({ storage, confirm: m => (prompts.push(m), answer) })
beforeEach(() => { store = new Map(); prompts = [] })

test("a link adds to the saved owners, never replaces them", () => {
  const mine = key(), other = key()
  store.set("fips-owners", mine)
  at("#owner=" + npubEncode(other))
  assert.deepEqual([...load(true)].sort(), [mine, other].sort())
  assert.deepEqual(store.get("fips-owners").split(" ").sort(), [mine, other].sort())
  assert.equal(prompts.length, 1)
  assert.match(prompts[0], new RegExp(npubEncode(other)))
  assert.equal(location.hash, "", "fragment scrubbed")
})

test("a declined link changes nothing and is still scrubbed", () => {
  const mine = key()
  store.set("fips-owners", mine)
  at("#owner=" + npubEncode(key()))
  assert.deepEqual([...load(false)], [mine])
  assert.equal(store.get("fips-owners"), mine)
  assert.equal(location.hash, "")
})

test("the first pairing asks too", () => {
  const k = key()
  at("#owner=" + npubEncode(k))
  assert.deepEqual([...load(false)], [])
  assert.equal(store.get("fips-owners"), undefined)
  at("#owner=" + npubEncode(k))
  assert.deepEqual([...load(true)], [k])
})

test("a link naming only known owners doesn't prompt", () => {
  const mine = key()
  store.set("fips-owners", mine)
  at("#owner=" + npubEncode(mine))
  assert.deepEqual([...load(true)], [mine])
  assert.equal(prompts.length, 0)
})

test("a multi-key link asks once per key, and a declined key is not added", () => {
  const stranger = key(), mine = key()
  at("#owner=" + [stranger, mine].map(npubEncode).join(","))
  const owners = loadOwners({ storage, confirm: m => (prompts.push(m), m.includes(npubEncode(mine))) })
  assert.equal(prompts.length, 2)
  assert.deepEqual([...owners], [mine], "Haven's owner (the first key) is the one accepted")
  assert.equal(store.get("fips-owners"), mine)
})

test("keys added by a link go after the saved owners, so Haven's owner does not change", () => {
  const mine = key(), other = key()
  store.set("fips-owners", mine)
  at("#owner=" + npubEncode(other))
  assert.deepEqual([...load(true)], [mine, other])
})

test("hash and scrub can be injected (no location/history globals needed)", () => {
  const k = key()
  let scrubbed = 0
  const owners = loadOwners({ storage, hash: "#owner=" + npubEncode(k), confirm: () => true, scrub: () => scrubbed++ })
  assert.deepEqual([...owners], [k])
  assert.equal(scrubbed, 1)
})
