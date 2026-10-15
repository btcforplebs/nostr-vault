// Web of Trust on the web: the web built from the follows' contact lists (net/wot.js), its key fraction checked against
// the iPhone's Swift. The globe's maths is in wot-globe.test.mjs. Made-up keys, a stubbed relay; nothing is fetched or
// published.
import test from "node:test"
import assert from "node:assert/strict"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPathText, fraction, hexPrefix, EXTENDED_MIN, RETRY_MS } from "../src/net/wot.js"
import { direction } from "../src/net/wot-globe.js"

const hex = (c, i = 0) => (c.repeat(63) + i.toString(16)).slice(-64)
const ME = hex("e")
const list = (pubkey, follows, created_at = 1) => ({ kind: 3, pubkey, created_at, tags: follows.map(p => ["p", p]) })

// Printed by TrustMap.fraction and TrustMap.direction themselves: both functions cut unedited from
// HavenApp/HavenApp/Models/TrustMap.swift (master b3a1d29c), compiled with swiftc, 2026-10-15.
// [key, fraction(0), fraction(8), fraction(16), direction x, y, z]. Real keys take the hex path; the rest take each of
// UInt32(_, radix: 16)'s edges (a "+", a "-0", a "-1", "0x", a space, a non-hex digit) and the FNV-1a fallback over
// UTF-8 bytes (non-ASCII keys).
const SWIFT = [
    ["82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", 0.508607836440206, 0.169657456921414, 0.170531388139352, -0.749565552128109, -0.040579551406732, -0.660685086157173],
    ["3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", 0.234142675762996, 0.795215976424515, 0.030023076804355, 0.080280778254543, 0.803084743783447, 0.590431952849030],
    ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", 0.999999999767169, 0.999999999767169, 0.999999999767169, 0.000030517578125, -0.000000000000045, 0.999999999534339],
    ["0000000000000000000000000000000000000000000000000000000000000000", 0.000000000000000, 0.000000000000000, 0.000000000000000, 0.000000000000000, 0.000000000000000, -1.000000000000000],
    ["ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789", 0.671111047500744, 0.137777777621523, 0.671111047500744, -0.327863795502065, -0.606370825534810, -0.724444444756955],
    ["not-hex-at-all", 0.122365342918783, 0.137179689947516, 0.504342899890617, 0.494528919014517, 0.478421193836571, -0.725640620104969],
    ["abc", 0.102659764466807, 0.504342899890617, 0.504342899890617, 0.799051392822830, 0.601199990444158, 0.008685799781233],
    ["+1234567zzzzzzzzzzzzzzzz", 0.004444444319233, 0.759983853669837, 0.995636613341048, 0.853852884253131, 0.023850269946720, 0.519967707339674],
    ["-0000000zz", 0.000000000000000, 0.341430393280461, 0.504342899890617, 0.948378995602098, 0.000000000000000, -0.317139213439077],
    ["1234567g00000000000000000000000000000000000000000000000000000000", 0.207001462578773, 0.000000000000000, 0.000000000000000, 0.000000000000000, 0.000000000000000, -1.000000000000000],
    ["-0000001aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0.110754624707624, 0.666666666511446, 0.666666666511446, 0.723589233916896, 0.604406741901023, 0.333333333022892],
    ["ééééééééabcdef01abcdef01", 0.067330246092752, 0.671111047500744, 0.671111047500744, 0.856783848789860, 0.385753125905191, 0.342222095001489],
    ["aé", 0.475946544669569, 0.504342899890617, 0.504342899890617, -0.988563940461111, 0.150551959476326, 0.008685799781233],
    ["0x123456bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 0.070338028017431, 0.733333333162591, 0.733333333162591, 0.799457549900093, 0.378272188309796, 0.466666666325182],
    [" 1234567cccccccccccccccccccccccccccccccccccccccccccccccccccccccc", 0.435631410451606, 0.799999999813735, 0.799999999813735, -0.735458393578893, 0.314803036455160, 0.599999999627471],
]

test("fraction and direction match the iPhone's TrustMap, hex path and fallback, from the Swift itself", () => {
  for (const [pk, f0, f8, f16, x, y, z] of SWIFT) {
    for (const [off, want] of [[0, f0], [8, f8], [16, f16]]) assert.ok(Math.abs(fraction(pk, off) - want) < 1e-12, `${pk} @${off}: ${fraction(pk, off)} vs ${want}`)
    const d = direction(pk)
    for (const [i, want] of [x, y, z].entries()) assert.ok(Math.abs(d[i] - want) < 1e-12, `${pk} direction[${i}]`)
  }
})

test("a real key's place is its leading hex digits, as on the phone", () => {
  assert.equal(fraction("8" + "0".repeat(63), 0), 0.5)
  assert.equal(fraction("0".repeat(8) + "4" + "0".repeat(55), 8), 0.25)
  assert.equal(hexPrefix("ffffffff"), 0xffffffff)
  assert.equal(hexPrefix("-0000001"), null)
  assert.equal(hexPrefix("abc"), null)
})

test("the web: follows, extended (followed by EXTENDED_MIN+ follows), further out, who links whom, who follows you", () => {
  const follows = Array.from({ length: 12 }, (_, i) => hex("1", i))
  const popular = hex("2"), oneLink = hex("3"), blockedPk = hex("4")
  const lists = new Map(follows.map((f, i) => [f, list(f, [popular, ...(i === 0 ? [oneLink, ME, follows[1], blockedPk] : [])])]))
  const web = buildWeb(ME, follows, lists, { blocked: new Set([blockedPk]) })
  assert.deepEqual(web.extended, [popular])
  assert.deepEqual(web.further, [oneLink])
  assert.equal(web.linkers.get(popular).length, 12)
  assert.deepEqual(web.linkers.get(oneLink), [follows[0]])
  assert.deepEqual(web.linkers.get(follows[1]), [follows[0]], "follows link each other too")
  assert.ok(web.followsMe.has(follows[0]) && !web.followsMe.has(follows[1]))
  assert.equal(web.layerOf(blockedPk), null, "blocked people aren't in the web")
  assert.equal(web.layerOf(ME), "me"); assert.equal(web.layerOf(follows[3]), "follow")
  assert.equal(EXTENDED_MIN, 10)
  // The cut-off itself: exactly EXTENDED_MIN follows is extended, one fewer is further out.
  const ten = hex("6"), nine = hex("7")
  const l2 = new Map(follows.map((f, i) => [f, list(f, [...(i < 10 ? [ten] : []), ...(i < 9 ? [nine] : [])])]))
  const w2 = buildWeb(ME, follows, l2)
  assert.equal(w2.layerOf(ten), "extended"); assert.equal(w2.layerOf(nine), "further")
})

test("nobody is reached through a follow you blocked", () => {
  const f1 = hex("1", 1), f2 = hex("1", 2), only = hex("5")
  const lists = new Map([[f1, list(f1, [only])], [f2, list(f2, [])]])
  assert.equal(buildWeb(ME, [f1, f2], lists).layerOf(only), "further")
  const w = buildWeb(ME, [f1, f2], lists, { blocked: new Set([f1]) })
  assert.equal(w.layerOf(only), null)
  assert.equal(w.layerOf(f1), null, "a blocked follow is hidden too, as in the feeds")
  assert.deepEqual(w.follows, [f2])
})

test("blocking filters the built web to exactly what building it with those blocks gives", () => {
  let n = 0
  const k = () => hex("a", 1 + n++ * 7919)
  const follows = Array.from({ length: 30 }, k), world = Array.from({ length: 60 }, k)
  const lists = new Map(follows.map((f, i) => [f, list(f, [
    ...world.filter((_, j) => (i * 7 + j * 3) % 5 < 2), ...follows.filter((_, j) => (i + j) % 4 === 0), ...(i % 3 ? [ME] : []),
  ])]))
  const built = buildWeb(ME, follows, lists, { extendedMin: 6 })
  for (const blocked of [new Set(), new Set([follows[0]]), new Set([follows[1], follows[2], world[0]]), new Set([world[5], world[9]]), new Set(follows.slice(0, 10))]) {
    const want = buildWeb(ME, follows, lists, { blocked, extendedMin: 6 }), got = filterWeb(built, lists, blocked)
    assert.deepEqual(got.follows, want.follows)
    assert.deepEqual(got.extended, want.extended)
    assert.deepEqual(got.further, want.further)
    assert.deepEqual([...got.followsMe].sort(), [...want.followsMe].sort())
    for (const pk of [...want.follows, ...want.extended, ...want.further]) assert.deepEqual(got.linkers.get(pk) ?? [], want.linkers.get(pk) ?? [], pk)
    for (const pk of blocked) assert.equal(got.layerOf(pk), null)
  }
  assert.equal(filterWeb(built, lists, new Set()), built, "nothing blocked: the same web, no work")
})

test("the trust path, as the iPhone's card says it", () => {
  const fs = [hex("1", 1), hex("1", 2), hex("1", 3), hex("1", 4)]
  const lists = new Map([[fs[0], list(fs[0], [hex("6"), hex("7"), ME])], [fs[1], list(fs[1], [hex("6"), hex("7")])], [fs[2], list(fs[2], [hex("7")])], [fs[3], list(fs[3], [hex("7")])]])
  const web = buildWeb(ME, fs, lists, { extendedMin: 99 })
  const name = pk => ({ [fs[0]]: "Ann", [fs[1]]: "Bob", [fs[2]]: "Cy" })[pk] ?? "Di"
  assert.equal(trustPathText(web, ME, name), "This is you")
  assert.equal(trustPathText(web, fs[0], name), "You follow them · they follow you")
  assert.equal(trustPathText(web, fs[1], name), "You follow them")
  assert.equal(trustPathText(web, hex("6"), name), "Followed by Ann and Bob, who you follow")
  assert.equal(trustPathText(web, hex("7"), name), "Followed by Ann, Bob and 2 others you follow")
  assert.equal(trustPathText(web, hex("9"), name), "Not in your web")
})

test("further out on the map is capped, by key, so the same people show every time", () => {
  const many = Array.from({ length: 50 }, (_, i) => hex("8", i * 104729))
  const a = shownByKey(many, 10), b = shownByKey([...many].reverse(), 10)
  assert.equal(a.length, 10); assert.deepEqual(a, b)
  assert.equal(shownByKey(many.slice(0, 5), 10).length, 5)
})

test("a follows' list that didn't come back is asked again after a while, or at once on Try again; never lost for the session", async () => {
  const me = hex("c", 99), f1 = hex("1", 21), f2 = hex("1", 22)
  let t = 1_000_000, asks = []
  const now = () => t
  let answer = async () => [] // the relay times out: nothing comes back
  const query = async (r, f) => { asks.push(f.authors); return answer(r, f) }
  assert.equal((await followLists(me, [f1, f2], { query, now })).size, 0)
  assert.equal(missingLists([f1, f2]), 2)
  await followLists(me, [f1, f2], { query, now })
  assert.equal(asks.length, 1, "not asked again straight away")
  answer = async (r, f) => f.authors.map(a => list(a, [hex("6")]))
  t += RETRY_MS
  assert.equal((await followLists(me, [f1, f2], { query, now })).size, 2, "asked again after RETRY_MS")
  assert.equal(missingLists([f1, f2]), 0)
  // A failed query (the relay down) marks nothing as having a list; Try again (retryMs 0) asks at once.
  const f3 = hex("1", 23)
  answer = async () => { throw new Error("relay down") }
  await followLists(me, [f1, f2, f3], { query, now })
  assert.equal(missingLists([f1, f2, f3]), 1)
  answer = async (r, f) => f.authors.map(a => list(a, []))
  asks = []
  await followLists(me, [f1, f2, f3], { query, now, retryMs: 0 })
  assert.deepEqual(asks, [[f3]])
  assert.equal(missingLists([f1, f2, f3]), 0)
})

test("Popular and the Web tab loading at once share one request per list", async () => {
  const me = hex("c", 98), fs = [hex("1", 31), hex("1", 32)]
  let asks = 0
  const query = async (r, f) => { asks++; await new Promise(res => setTimeout(res, 20)); return f.authors.map(a => list(a, [hex("6")])) }
  const [a, b] = await Promise.all([followLists(me, fs, { query }), followLists(me, fs, { query })])
  assert.equal(asks, 1)
  assert.equal(a.size, 2); assert.equal(b.size, 2)
})

test("follows' lists: asked for once each this session, a new follow on its own, newest list wins", async () => {
  const me = hex("c"), f1 = hex("1", 11), f2 = hex("1", 12), f3 = hex("1", 13)
  const asked = []
  const query = async (r, f) => { asked.push(f.authors); return [list(f1, [hex("6")], 1), list(f1, [hex("7")], 5), list(hex("d"), [hex("6")])].filter(e => f.authors.includes(e.pubkey) || e.pubkey === hex("d")) }
  const got = await followLists(me, [f1, f2], { query })
  assert.deepEqual([...got.keys()], [f1])
  assert.deepEqual(got.get(f1).tags, [["p", hex("7")]], "the newest")
  await followLists(me, [f1, f2, f3], { query })
  assert.deepEqual(asked, [[f1, f2], [f3]], "only the new follow is asked for")
  await followLists(me, [f1, f2, f3], { query: async () => assert.fail("nothing new to ask") })
})
