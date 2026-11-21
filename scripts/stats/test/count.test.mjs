import { test } from "node:test"
import assert from "node:assert/strict"
import { platformOf, nvPlatform, collectPosters, mergePosters, mainPlatform, publicTotals, postersFromJson, postersToJson, isExcluded } from "../count.mjs"

const pk = c => c.repeat(64).slice(0, 64)
const note = (id, pubkey, created_at, client, kind = 1) => ({ id, pubkey, created_at, kind, tags: client ? [["client", client]] : [], content: "" })

test("platformOf reads the values every app writes", () => {
  assert.equal(platformOf("Nostr Vault on iOS"), "iPhone")
  assert.equal(platformOf("Nostr Vault on iPadOS"), "iPad")
  assert.equal(platformOf("Nostr Vault on MacOS"), "Mac")
  assert.equal(platformOf("Nostr Vault on Android"), "Android")
  assert.equal(platformOf("Nostr Vault on Web"), "Web")
  assert.equal(platformOf("Nostr Vault on Linux"), "Linux") // the Linux desktop window
  assert.equal(platformOf("Nostr Vault"), "Other")
  assert.equal(platformOf("Damus"), null)
  assert.equal(platformOf("nostr-vault"), null) // file notes, not posts
  assert.equal(platformOf(undefined), null)
})

test("nvPlatform counts kind 1 and 1111 only", () => {
  assert.equal(nvPlatform(note("a", pk("1"), 1, "Nostr Vault on Android")), "Android")
  assert.equal(nvPlatform(note("a", pk("1"), 1, "Nostr Vault on Android", 1111)), "Android")
  assert.equal(nvPlatform(note("a", pk("1"), 1, "Nostr Vault on Android", 7)), null)
  assert.equal(nvPlatform(note("a", pk("1"), 1, null)), null)
})

test("collectPosters dedupes notes across relays and skips excluded keys", () => {
  const logen = "61bf790b" + "0".repeat(56)
  assert.ok(isExcluded(logen))
  const posters = collectPosters([
    note("a", pk("1"), 100, "Nostr Vault on iOS"),
    note("a", pk("1"), 100, "Nostr Vault on iOS"), // same note from a second relay
    note("b", pk("1"), 300, "Nostr Vault on Android"),
    note("c", pk("2"), 200, "Amethyst"),
    note("d", logen, 200, "Nostr Vault on iOS"),
  ])
  assert.deepEqual([...posters.keys()], [pk("1")])
  assert.deepEqual(posters.get(pk("1")), { first: 100, last: 300, notes: { iPhone: 1, Android: 1 } })
})

test("mergePosters never loses a poster today's scan missed, and widens dates", () => {
  const previous = new Map([[pk("1"), { first: 50, last: 80, notes: { Web: 3 } }], [pk("2"), { first: 10, last: 20, notes: { Mac: 1 } }]])
  const today = new Map([[pk("1"), { first: 60, last: 500, notes: { Web: 4 } }]])
  const merged = mergePosters(previous, today)
  assert.equal(merged.size, 2)
  assert.deepEqual(merged.get(pk("1")), { first: 50, last: 500, notes: { Web: 4 } })
  assert.deepEqual(merged.get(pk("2")), previous.get(pk("2")))
})

test("mainPlatform takes the most-used platform", () => {
  assert.equal(mainPlatform({ notes: { iPhone: 2, Android: 5 } }), "Android")
  assert.equal(mainPlatform({ notes: { iPad: 1 } }), "iPad")
  assert.equal(mainPlatform({ notes: {} }), "Other")
})

test("publicTotals counts windows from each poster's last note", () => {
  const now = 1_000_000_000
  const day = 86400
  const posters = new Map([
    [pk("1"), { first: 0, last: now - 1 * day, notes: { Android: 1 } }],
    [pk("2"), { first: 0, last: now - 10 * day, notes: { iPhone: 1 } }],
    [pk("3"), { first: 0, last: now - 40 * day, notes: { iPhone: 1, Web: 2 } }],
  ])
  const t = publicTotals(posters, { now, downloads: 207, relays: 6 })
  assert.equal(t.posting_users, 3)
  assert.equal(t.active_7d, 1)
  assert.equal(t.active_30d, 2)
  assert.deepEqual(t.by_platform, { Android: 1, iPhone: 1, iPad: 0, Mac: 0, Linux: 0, Web: 1 })
  assert.equal(t.github_downloads, 207)
})

test("the public file holds no key, no list and no per-person figure", () => {
  const posters = new Map([[pk("a"), { first: 1, last: 2, notes: { Web: 1 } }], [pk("b"), { first: 1, last: 2, notes: { Mac: 9 } }]])
  const text = JSON.stringify(publicTotals(posters, { now: 3, downloads: null, relays: 7 }))
  assert.doesNotMatch(text, /[0-9a-f]{64}/)
  assert.doesNotMatch(text, /npub1/)
  assert.doesNotMatch(text, /\[/) // no arrays at all: every value is a total
  // Positive control: the same check does fire on the state file, which does hold keys.
  assert.match(JSON.stringify(postersToJson(posters)), /[0-9a-f]{64}/)
})

test("postersFromJson drops anything that is not a poster record", () => {
  const m = postersFromJson({ [pk("1")]: { first: 1, last: 2, notes: {} }, nothex: { last: 1 }, [pk("2")]: { first: 1 } })
  assert.deepEqual([...m.keys()], [pk("1")])
  assert.equal(postersFromJson(null).size, 0)
})

test("a poster from the Linux desktop window counts under Linux, not Other", () => {
  const posters = collectPosters([note("l1", pk("4"), 10, "Nostr Vault on Linux"), note("l2", pk("4"), 20, "Nostr Vault on Linux")])
  const t = publicTotals(posters, { now: 30, downloads: null, relays: 7 })
  assert.equal(t.by_platform.Linux, 1)
  assert.equal(Object.values(t.by_platform).reduce((a, b) => a + b, 0), 1)
})
