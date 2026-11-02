// Events dated ahead of the clock (Logen 11-02, #1572 on the apps): never drawn, kept or used as a since.
import test from "node:test"
import assert from "node:assert/strict"
import { FUTURE_SKEW, isFuture, clampSince, eachRelay, fetchInbound, readInbound, readOwn, newestShown, sinceKept } from "../src/net/vault-lists.js"

const now = () => Math.floor(Date.now() / 1000)
const ev = (id, created_at) => ({ id: id.padEnd(64, "0"), kind: 1, pubkey: "a".repeat(64), tags: [["p", "b".repeat(64)]], content: "", created_at })

test("future means more than ten minutes ahead", () => {
  const t = 1_800_000_000
  assert.equal(FUTURE_SKEW, 600)
  assert.equal(isFuture({ created_at: t - 86400 * 90 }, t), false)
  assert.equal(isFuture({ created_at: t + 600 }, t), false)
  assert.equal(isFuture({ created_at: t + 601 }, t), true)
})

test("a since is never later than the clock allows", () => {
  const t = 1_800_000_000
  assert.equal(clampSince(undefined, t), undefined)
  assert.equal(clampSince(t - 3600, t), t - 3600)
  assert.equal(clampSince(t + 31_536_000, t), t + 540)
})

test("relay answers and stored reads drop future-dated events", async () => {
  const year = now() + 31_536_000
  const got = await eachRelay(["wss://a"], {}, () => {}, { query: async () => [ev("1", now() - 60), ev("2", year)] })
  assert.deepEqual(got.map(e => e.id[0]), ["1"])
  const vault = {
    outbox: { query: async () => [ev("3", now()), ev("4", year)] },
    inbox: { query: async () => [ev("5", now() - 5), ev("6", year)] },
  }
  assert.deepEqual((await readOwn(vault, "b".repeat(64))).map(e => e.id[0]), ["3"])
  assert.deepEqual((await readInbound(vault, "b".repeat(64))).map(e => e.id[0]), ["5"])
})

test("a fetch asked from a future mark asks no later than the clock allows", async () => {
  let asked
  await fetchInbound({}, "b".repeat(64), ["wss://a"], { since: now() + 31_536_000, query: async (r, f) => { asked = f; return [] } })
  assert.ok(asked.since <= now() + FUTURE_SKEW)
})

test("the newest shown and a kept tab's since can't sit in the future", () => {
  assert.ok(newestShown([ev("7", now() + 31_536_000)]) <= now() + FUTURE_SKEW)
  assert.ok(sinceKept({ at: now() + 31_536_000 }) <= now() + FUTURE_SKEW)
})
