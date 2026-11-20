// Follower lists are asked whole once per browser, then only what changed since the last answered ask (Tidy's perf
// audit 11-20, W1/W2: every load re-downloaded ~180 MB of lists). Throwaway keys and fake relays: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { fetchFollowerLists, keepLists, listsChecked, readLists, FULL_LISTS_LIMIT } from "../src/net/vault-lists.js"

const person = () => getPublicKey(generateSecretKey())
const ME = person(), ALICE = person()
const memStorage = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const list = (created_at = Math.floor(Date.now() / 1000) - 100) => ({ id: "a".repeat(64), kind: 3, pubkey: ALICE, created_at, tags: [["p", ME]], content: "" })
const sleep = ms => new Promise(r => setTimeout(r, ms))

test("a first ask is whole, at the full page, and marks the lists checked; the next asks only since then", async () => {
  const storage = memStorage(), asked = []
  const query = async (r, f) => { asked.push(f); return [list()] }
  const kept = []
  await fetchFollowerLists(ME, ["wss://a", "wss://b"], { limit: 100, storage, query, on: l => { kept.push(...l); keepLists(ME, kept, storage) } })
  assert.equal(asked.length, 2)
  assert.equal(asked[0].since, undefined, "never asked: the whole set")
  assert.equal(asked[0].limit, FULL_LISTS_LIMIT, "a whole ask never takes the caller's smaller page")
  const at = listsChecked(ME, storage)["wss://a"]
  assert.ok(at > 0 && at <= Math.floor(Date.now() / 1000))
  assert.equal(listsChecked(ME, storage)["wss://b"], at)
  asked.length = 0
  await fetchFollowerLists(ME, ["wss://a"], { limit: 100, storage, query })
  assert.equal(asked[0].since, at - 60, "a return asks from the last check, a minute's slack")
  assert.equal(asked[0].limit, 100)
})

test("marks are per relay: a relay first met later still gets its whole ask", async () => {
  const storage = memStorage(), asked = new Map()
  const query = async ([url], f) => { asked.set(url, f); return [list()] }
  keepLists(ME, [], storage)
  await fetchFollowerLists(ME, ["wss://a"], { storage, query })
  asked.clear()
  await fetchFollowerLists(ME, ["wss://a", "wss://new"], { storage, query })
  assert.ok(asked.get("wss://a").since > 0, "the checked relay: only what changed")
  assert.equal(asked.get("wss://new").since, undefined, "the new relay: the whole set")
  assert.ok(listsChecked(ME, storage)["wss://new"] > 0)
})

test("a relay that fails keeps no mark while the others get theirs", async () => {
  const storage = memStorage()
  keepLists(ME, [], storage)
  await fetchFollowerLists(ME, ["wss://ok", "wss://down"], { storage, query: async ([url]) => { if (url === "wss://down") throw new Error("down"); return [] } })
  assert.deepEqual(Object.keys(listsChecked(ME, storage)), ["wss://ok"])
})

test("an ask from later than the mark does not move it: lists between the two were never asked for", async () => {
  const storage = memStorage()
  const query = async () => []
  const now = Math.floor(Date.now() / 1000)
  keepLists(ME, [], storage)
  await fetchFollowerLists(ME, ["wss://a"], { since: now - 30, storage, query })
  assert.deepEqual(listsChecked(ME, storage), {}, "the notify watch's since-now ask leaves a never-checked relay unchecked")
  await fetchFollowerLists(ME, ["wss://a"], { storage, query })
  const at = listsChecked(ME, storage)["wss://a"]
  assert.ok(at > 0)
  storage.setItem(`nv-vault-follower-lists-checked:${ME}`, JSON.stringify({ "wss://a": at - 100 }))
  await fetchFollowerLists(ME, ["wss://a"], { since: at - 50, storage, query })
  assert.equal(listsChecked(ME, storage)["wss://a"], at - 100, "from after the mark: it stays")
  await fetchFollowerLists(ME, ["wss://a"], { since: at - 200, storage, query })
  assert.ok(listsChecked(ME, storage)["wss://a"] >= at, "from before the mark: it moves on")
})

test("every relay failing leaves the mark where it was", async () => {
  const storage = memStorage()
  await assert.rejects(fetchFollowerLists(ME, ["wss://a"], { storage, query: async () => { throw new Error("down") } }))
  assert.equal(storage.getItem(`nv-vault-follower-lists-checked:${ME}`), null)
})

test("lists that can't be kept, or are gone, take the mark with them: the next ask is whole again", async () => {
  const storage = memStorage()
  keepLists(ME, [list()], storage)
  await fetchFollowerLists(ME, ["wss://a"], { storage, query: async () => [] })
  assert.ok(listsChecked(ME, storage)["wss://a"] > 0)
  storage.setItem = () => { throw new Error("QuotaExceededError") }
  keepLists(ME, [list()], storage)
  assert.deepEqual(listsChecked(ME, storage), {})
  const fresh = memStorage()
  fresh.setItem(`nv-vault-follower-lists-checked:${ME}`, JSON.stringify({ "wss://a": 1795000000 }))
  assert.deepEqual(listsChecked(ME, fresh), {}, "a mark with no kept lists counts for nothing")
  assert.deepEqual(readLists(ME, fresh), [])
})

test("a second whole ask while one is out joins it: the relays are asked once, both callers get the lists", async () => {
  const storage = memStorage()
  let asks = 0
  const query = async () => { asks++; await sleep(20); return [list()] }
  const a = [], b = []
  let settled = 0
  await Promise.all([
    fetchFollowerLists(ME, ["wss://a"], { storage, query, on: l => a.push(...l) }),
    fetchFollowerLists(ME, ["wss://a"], { storage, query, on: l => b.push(...l), onSettled: () => settled++ }),
  ])
  assert.equal(asks, 1)
  assert.equal(a.length, 1)
  assert.equal(b.length, 1)
  assert.equal(settled, 1)
})
