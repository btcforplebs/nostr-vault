// Follows' names and pictures: read from Haven /feed first, the network only for the rest, and what the network
// returns is written into Haven so the next load (a reload, offline) finds it there.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"

const profile = (sk, name, at) => finalizeEvent({ kind: 0, created_at: at, tags: [], content: JSON.stringify({ name }) }, sk)

// Haven /feed as profiles.js sees it: query + event, newest kind 0 per author wins.
function fakeVault() {
  const stored = new Map()
  return {
    stored,
    feed: {
      async query(f) { return f.authors.map(pk => stored.get(pk)).filter(Boolean) },
      async event(ev) { const have = stored.get(ev.pubkey); if (!have || have.created_at < ev.created_at) stored.set(ev.pubkey, ev); return { ok: true } },
    },
  }
}
// A fresh copy of the module, the way a page reload starts with an empty memory cache.
let n = 0
const load = () => import(`../src/net/profiles.js?reload=${n++}`)

test("profiles from the network are written into Haven and found there after a reload, with no network", async () => {
  const a = generateSecretKey(), b = generateSecretKey()
  const vault = fakeVault()
  const asked = []
  const net = async (relays, f) => { asked.push(f.authors); return [profile(a, "alice", 100), profile(b, "bob", 100)] }

  const first = await load()
  await first.fetchProfiles(vault, [getPublicKey(a), getPublicKey(b)], [], { query: net })
  assert.equal(first.getProfile(getPublicKey(a)).name, "alice")
  assert.equal(vault.stored.size, 2, "both written into Haven")

  const offline = async () => { throw new Error("network used") }
  const second = await load()
  await second.fetchProfiles(vault, [getPublicKey(a), getPublicKey(b)], [], { query: offline })
  assert.equal(second.getProfile(getPublicKey(b)).name, "bob", "read back from Haven")
  assert.equal(asked.length, 1)
})

test("only the pubkeys Haven doesn't have go to the network", async () => {
  const a = generateSecretKey(), b = generateSecretKey()
  const vault = fakeVault()
  await vault.feed.event(profile(a, "alice", 100))
  const asked = []
  const net = async (relays, f) => { asked.push(...f.authors); return [profile(b, "bob", 100)] }
  const m = await load()
  await m.fetchProfiles(vault, [getPublicKey(a), getPublicKey(b)], [], { query: net })
  assert.deepEqual(asked, [getPublicKey(b)])
  assert.equal(m.getProfile(getPublicKey(a)).name, "alice")
  assert.equal(m.getProfile(getPublicKey(b)).name, "bob")
})

test("force asks the network even for cached pubkeys, and a newer kind 0 replaces the older one", async () => {
  const a = generateSecretKey()
  const vault = fakeVault()
  await vault.feed.event(profile(a, "old", 100))
  const m = await load()
  await m.fetchProfiles(vault, [getPublicKey(a)], [], { query: async () => [profile(a, "new", 200)], force: true })
  assert.equal(m.getProfile(getPublicKey(a)).name, "new")
  assert.equal(JSON.parse(vault.stored.get(getPublicKey(a)).content).name, "new")
})
