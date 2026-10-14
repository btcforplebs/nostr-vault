// The Popular feed: a day of likes, reposts and zaps from the user's web of trust, scored as the iPhone does
// (haven-go dvm.go), and nothing written to Haven /feed.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { engagementWeight, targetOf, reactorOf, tally, rankTargets, scoreNotes, trustSet, fetchPopular } from "../src/net/popular.js"

const hex = c => c.repeat(64)
const N1 = hex("1"), N2 = hex("2"), N3 = hex("3")
const AUTHOR = hex("a"), R1 = hex("b"), R2 = hex("c"), R3 = hex("d"), STRANGER = hex("e")
const like = (who, note, extra = []) => ({ id: Math.random().toString(16).slice(2), kind: 7, pubkey: who, tags: [...extra, ["e", note]] })
const repost = (who, note) => ({ id: Math.random().toString(16).slice(2), kind: 6, pubkey: who, tags: [["e", note]] })

test("likes weigh 1, reposts 2, zaps 3; other kinds nothing", () => {
  assert.deepEqual([7, 6, 9735, 1].map(engagementWeight), [1, 2, 3, 0])
})

test("the note is the last e tag, so a like on a reply credits the reply, not the thread root", () => {
  assert.equal(targetOf(like(R1, N2, [["e", N1]])), N2)
  assert.equal(targetOf({ tags: [["e", "short"]] }), "")
})

test("a zap counts for the zapper in the signed zap request, not the wallet that signed the receipt", () => {
  const sk = generateSecretKey()
  const req = finalizeEvent({ kind: 9734, created_at: 1, tags: [["e", N1]], content: "" }, sk)
  const receipt = { kind: 9735, pubkey: hex("f"), tags: [["e", N1], ["description", JSON.stringify(req)]] }
  assert.equal(reactorOf(receipt), getPublicKey(sk))
  assert.equal(reactorOf({ ...receipt, tags: [["e", N1], ["description", JSON.stringify({ ...req, pubkey: R1 })]] }), "", "a forged request counts for nobody")
  assert.equal(reactorOf({ ...receipt, tags: [["e", N1]] }), "")
})

test("only trusted people count, once per note, at the strongest thing they did", () => {
  const t = tally([like(R1, N1), repost(R1, N1), like(R1, N1), like(STRANGER, N1), like(R2, N1)], new Set([R1, R2]))
  assert.deepEqual([...t.get(N1)], [[R1, 2], [R2, 1]])
})

test("a note needs three people; the rest rank by summed weight, ties by id", () => {
  const trusted = new Set([R1, R2, R3])
  const t = tally([
    like(R1, N1), like(R2, N1), like(R3, N1), // 3
    repost(R1, N2), repost(R2, N2), like(R3, N2), // 5
    like(R1, N3), like(R2, N3), // only two people
  ], trusted)
  assert.deepEqual(rankTargets(t), [N2, N1])
})

test("the author's own like doesn't count, and can drop a note under the floor", () => {
  const t = tally([like(AUTHOR, N1), like(R1, N1), like(R2, N1)], new Set([AUTHOR, R1, R2]))
  assert.deepEqual(rankTargets(t), [N1], "three people react")
  assert.deepEqual(scoreNotes([{ id: N1, pubkey: AUTHOR, created_at: 0 }], t, { now: 0 }), [], "but one is the author")
})

test("scores decay 5% an hour after 12 hours, down to a fifth", () => {
  const trusted = new Set([R1, R2, R3])
  const t = tally([N1, N2].flatMap(n => [repost(R1, n), repost(R2, n), repost(R3, n)]).concat([like(R1, N3), like(R2, N3), like(R3, N3)]), trusted)
  const now = 100 * 3600
  const old = { id: N1, pubkey: R1 + "", created_at: now - 40 * 3600 } // 6 * 0.2 = 1.2
  const fresh = { id: N3, pubkey: AUTHOR, created_at: now - 3600 } // 3 * 1
  const midday = { id: N2, pubkey: AUTHOR, created_at: now - 22 * 3600 } // 6 * 0.5 = 3, tie with fresh: id order
  const got = scoreNotes([old, fresh, midday], t, { now })
  // old's author R1 reposted it, so R1 is left out there: two people, under the floor.
  assert.deepEqual(got.map(n => n.id), [N2, N3])
})

test("no author has more than three notes on the page", () => {
  const trusted = new Set([R1, R2, R3])
  const ids = ["4", "5", "6", "7"].map(hex)
  const t = tally(ids.flatMap(n => [like(R1, n), like(R2, n), like(R3, n)]), trusted)
  const got = scoreNotes(ids.map(id => ({ id, pubkey: AUTHOR, created_at: 0 })), t, { now: 0 })
  assert.equal(got.length, 3)
})

test("the trust set is the user, their follows and who those follow, newest contact list each", async () => {
  const asked = []
  const query = async (r, f) => { asked.push(f); return [
    { kind: 3, pubkey: R1, created_at: 1, tags: [["p", STRANGER]] },
    { kind: 3, pubkey: R1, created_at: 2, tags: [["p", R3]] },
    { kind: 3, pubkey: STRANGER, created_at: 9, tags: [["p", N1]] }, // not a follow: ignored
  ] }
  const set = await trustSet(AUTHOR, [R1, R2], ["wss://r"], { query })
  assert.deepEqual([...set].sort(), [AUTHOR, R1, R2, R3].sort())
  assert.deepEqual(asked, [{ kinds: [3], authors: [R1, R2], limit: 2 }])
  await trustSet(AUTHOR, [R1, R2], ["wss://r"], { query: async () => assert.fail("built once") })
})

test("a Popular page: engagement in, scored notes out, Haven /feed only read", async () => {
  const now = 1_000_000
  const writes = [], filters = []
  const vault = { feed: { query: async f => (f.ids.includes(N1) ? [{ id: N1, kind: 1, pubkey: AUTHOR, created_at: now - 60, tags: [], content: "in haven" }] : []), event: async ev => writes.push(ev) } }
  const query = async (r, f) => {
    filters.push(f)
    if (f.kinds?.[0] === 3) return [{ kind: 3, pubkey: R1, created_at: 1, tags: [["p", R2], ["p", R3]] }]
    if (f.ids) return [{ id: N2, kind: 1, pubkey: STRANGER, created_at: now - 60, tags: [], content: "from a relay" }, { id: N3, kind: 1, pubkey: STRANGER, created_at: 0, tags: [], content: "not asked for" }]
    if (f.authors) return [repost(R1, N2)]
    return [like(R1, N1), like(R2, N1), like(R3, N1), like(R2, N2), like(R3, N2), like(STRANGER, N2)]
  }
  const { notes, trusted } = await fetchPopular({ me: hex("9"), follows: [R1], relays: ["wss://r"], vault, now, query })
  assert.deepEqual(notes.map(n => n.id), [N2, N1], "N2: repost 2 + 1 + 1; N1: 1 + 1 + 1")
  assert.equal(trusted, 4)
  assert.ok(filters.some(f => f.since === now - 86400 && !f.authors && f.limit === 5000), "everyone's last day")
  assert.ok(filters.some(f => f.authors?.includes(R1) && f.kinds.join() === "7,6"), "and the follows' own")
  assert.deepEqual(filters.find(f => f.ids).ids, [N2], "N1 came from Haven, only N2 from the relays")
  assert.deepEqual(writes, [], "nothing written to Haven /feed")
})
