// Search's For you (src/net/for-you.js) against the iPhone's SearchRecommendations: who is recommended, which topics,
// which notes, in what order.
import test from "node:test"
import assert from "node:assert/strict"
import { vouchesFrom, recommendedPeople, topTags, interests, pickedNotes, reactedIds, followedTags, normalizeTag, MIN_VOUCHES } from "../src/net/for-you.js"

const pk = c => c.repeat(64)
const [ME, A, B, C, X, Y, Z] = ["0", "a", "b", "c", "d", "e", "f"].map(pk)
const list = ps => ({ tags: ps.map(p => ["p", p]) })

test("vouches count each follow once, however often their list names someone", () => {
  const v = vouchesFrom([A, B, A], new Map([[A, list([X, X, Y])], [B, list([X])]]))
  assert.equal(v.get(X), 2)
  assert.equal(v.get(Y), 1)
})

test("people: at least MIN_VOUCHES, not you / followed / blocked, most vouched first, ties by pubkey", () => {
  assert.equal(MIN_VOUCHES, 2)
  const v = new Map([[X, 3], [Z, 2], [Y, 2], [ME, 9], [A, 9], [C, 1], [B, 5]])
  const got = recommendedPeople(v, { following: new Set([A]), me: ME, blocked: new Set([B]) })
  assert.deepEqual(got, [{ pubkey: X, vouches: 3 }, { pubkey: Y, vouches: 2 }, { pubkey: Z, vouches: 2 }])
  assert.equal(recommendedPeople(new Map([...Array(12)].map((_, i) => [i.toString(16).padStart(64, "1"), 4])), { following: new Set(), me: ME }).length, 8)
})

test("topics: followed first (normalized, once), then the most used tags on notes you engaged with", () => {
  assert.equal(normalizeTag("##Bitcoin "), "bitcoin")
  const engaged = [[["t", "Nostr"], ["t", "nostr"]], [["t", "nostr"], ["t", "art"]], [["t", "bitcoin"]], [["t", "zz"]]]
  assert.deepEqual(topTags(engaged), ["nostr", "art", "bitcoin", "zz"], "once per note, ties alphabetical")
  assert.deepEqual(interests(["#Bitcoin", "bitcoin"], engaged), ["bitcoin", "nostr", "art", "zz"])
  assert.equal(interests([], [[...Array(20)].map((_, i) => ["t", `t${i}`])]).length, 12)
})

test("picked notes: by topic hits, then followed, then vouches, then newest; one per author; skips you, blocked, reacted", () => {
  const n = (id, pubkey, tags, at = 100) => ({ id: id.repeat(64), pubkey, created_at: at, tags: tags.map(t => ["t", t]) })
  const notes = [
    n("1", X, ["art"], 300), // vouched 5, one hit
    n("2", A, ["art"], 100), // followed, one hit
    n("3", Y, ["art", "nostr"], 50), // two hits
    n("4", Y, ["art", "nostr"], 60), // same author, newer: wins over 3
    n("5", ME, ["art", "nostr"]), // yours
    n("6", B, ["art", "nostr"]), // blocked
    n("7", Z, ["art", "nostr"]), // reacted
    n("8", C, ["cats"]), // no topic
  ]
  const got = pickedNotes(notes, { topics: ["Art", "nostr"], following: new Set([A]), vouches: new Map([[X, 5]]), me: ME, blocked: new Set([B]), seen: new Set(["7".repeat(64)]) })
  assert.deepEqual(got.map(e => e.id[0]), ["4", "2", "1"])
  assert.deepEqual(pickedNotes(notes, { topics: [], following: new Set(), vouches: new Map(), me: ME }), [])
})

test("reacted ids take the last e tag; followed tags read a kind 10015", () => {
  assert.deepEqual([...reactedIds([{ tags: [["e", A], ["e", B], ["p", C]] }, { tags: [["e", "bad"]] }])], [B])
  assert.deepEqual(followedTags({ tags: [["t", "art"], ["p", A], ["t", ""]] }), ["art"])
  assert.deepEqual(followedTags(undefined), [])
})
