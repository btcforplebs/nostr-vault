// The dashboard's GM tile (twin of Android GreetingCountsTest and iPhone GreetingCountsTests).
import test from "node:test"
import assert from "node:assert/strict"
import { greetings, countGreetings, readAll, greetingLabel, readGreetings } from "../src/net/greeting-counts.js"

const me = "aa".repeat(32), other = "bb".repeat(32)
const note = (id, content, at, kind = 1, pubkey = me) => ({ id, pubkey, kind, created_at: at, content })
const set = s => [...greetings(s)].sort()

test("plain greetings count as GM", () => {
  for (const s of ["gm", "GM", "gm!", "Gm.", "Good Morning", "good morning!!", "GOOD MORNING", "gmgm", "gmmm", "gm ☕", "  gm\n"]) assert.deepEqual(set(s), ["gm"], s)
})

test("pura vida and PV get their own greeting", () => {
  for (const s of ["Pura Vida", "pura vida!", "PV", "pv 🌴"]) assert.deepEqual(set(s), ["pv"], s)
  assert.deepEqual(set("GM, pura vida"), ["gm", "pv"])
})

test("a greeting with a couple of words, a photo or a tag still counts", () => {
  for (const s of ["gm nostr", "Good morning everyone, frens", "gm https://image.example/a.jpg", "#gm gm", "gm nostr:npub1xyz", "gm #coffee"]) assert.deepEqual(set(s), ["gm"], s)
})

test("a note that only contains gm does not count", () => {
  for (const s of ["gm, today we ship the new relay build", "I said gm to everyone at the meetup", "the gm of the hotel was great tonight", "good", "morning", "programming", "pvc pipes", "", "https://example.com/gm", "#gm"]) assert.deepEqual(set(s), [], s)
})

test("counts only my kind 1 notes, today and all time, once per id", () => {
  const today = 1_000_000
  const notes = [note("1", "gm", today + 10), note("2", "GM!", today - 10), note("2", "GM!", today - 10), note("3", "Pura Vida", today + 5), note("4", "pv", today - 100), note("5", "gm pura vida", today - 200), note("6", "gm, here is a long update about the release", today + 1), note("7", "gm", today + 1, 1, other), note("8", "gm", today + 1, 7)]
  assert.deepEqual(countGreetings(notes, me, today), { gmToday: 1, gmAll: 3, pvToday: 1, pvAll: 3 })
})

test("reads every page back with until, even when the store caps below the page size", async () => {
  const all = [note("e", "gm", 50), note("d", "gm", 40), note("c", "gm", 30), note("b", "gm", 30), note("a", "gm", 10)]
  const filters = []
  const got = await readAll(me, async f => { filters.push(f); return all.filter(e => e.created_at <= (f.until ?? Infinity)).slice(0, 2) }, { pageSize: 500 })
  assert.deepEqual(got.map(e => e.id), ["e", "d", "c", "b", "a"])
  assert.deepEqual(filters[0], { kinds: [1], authors: [me], limit: 500 })
})

test("a store that can't answer gives no counts", async () => {
  assert.equal(await readGreetings({ query: async () => { throw new Error("closed") } }, me), null)
})

test("label reads GM then PV", () => assert.equal(greetingLabel(12, 3), "GM 12 · PV 3"))
