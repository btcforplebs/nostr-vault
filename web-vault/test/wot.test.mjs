// Web of Trust on the web: the web built from the follows' contact lists (net/wot.js) and the 2D map's maths
// (net/wot-map.js), checked against the iPhone's Swift for where people sit. Made-up keys, a stubbed relay; nothing
// is fetched or published.
import test from "node:test"
import assert from "node:assert/strict"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPathText, fraction, EXTENDED_MIN, RETRY_MS } from "../src/net/wot.js"
import {
  place, layout, spread, FACE_ROOM, ZONES, unit, newCamera, pan, fling, zoomBy, home, glideTo, step, moving, limit, visible, hit, toScreen, ZOOM_MAX, ZOOM_MIN, MAX_SPEED,
} from "../src/net/wot-map.js"

const hex = (c, i = 0) => (c.repeat(63) + i.toString(16)).slice(-64)
const ME = hex("e")
const list = (pubkey, follows, created_at = 1) => ({ kind: 3, pubkey, created_at, tags: follows.map(p => ["p", p]) })

test("a person sits where the iPhone puts them: fraction and place match the Swift (TrustMap.fraction, GlobeFlat.place)", () => {
  // Printed by the Swift functions compiled with swiftc, 2026-10-15.
  const cases = [
    ["82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", 0.873802130343, -0.071229513674, -0.602062433614],
    ["3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", 0.462535042549, 0.185515403296, 0.286640100915],
    ["f".repeat(64), 0.331829221221, -0.408463551370, 0.256539352639],
  ]
  for (const [pk, f16, x, y] of cases) {
    assert.ok(Math.abs(fraction(pk, 16) - f16) < 1e-11, pk)
    const [px, py] = place(pk, 1)
    assert.ok(Math.abs(px - x) < 1e-11 && Math.abs(py - y) < 1e-11, pk)
  }
})

test("each layer lands in its own zone of the map, you in the middle", () => {
  const radius = (pk, z) => Math.hypot(...place(pk, z))
  for (let i = 0; i < 200; i++) {
    const pk = hex("a", i * 7919)
    const r1 = radius(pk, 1), r2 = radius(pk, 2), r3 = radius(pk, 3)
    assert.ok(r1 >= 0.06 - 1e-9 && r1 <= 0.64 + 1e-9)
    assert.ok(r2 >= 0.68 - 1e-9 && r2 <= 0.83 + 1e-9)
    assert.ok(r3 >= 0.86 - 1e-9 && r3 <= 0.98 + 1e-9)
  }
  assert.deepEqual(place(ME, 0), [0, 0])
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

test("layout: you first, then follows, extended and the further out shown", () => {
  const f = hex("1", 1)
  const web = buildWeb(ME, [f], new Map([[f, list(f, [hex("6")])]]))
  const nodes = layout(web, web.further)
  assert.deepEqual(nodes.map(n => n.layer), ["me", "follow", "further"])
  assert.deepEqual([nodes[0].x, nodes[0].y], [0, 0])
})

const W = 390, H = 700

test("the camera: drag moves it, but never past the network's edge plus a margin", () => {
  let c = pan(newCamera(), 50, -20, W, H)
  assert.deepEqual(c.offset, [50, -20])
  c = pan(c, 1e6, 0, W, H)
  assert.ok(Math.abs(Math.hypot(...c.offset) - limit(c, W, H)) < 1e-6)
  assert.ok(limit(c, W, H) > unit(W, H) - W / 2, "the plane is several screens across")
})

test("zoom keeps the point under the pointer still, and stays in range", () => {
  const c0 = pan(newCamera(), 30, 40, W, H)
  const px = 100, py = 500
  const before = [(px - W / 2 - c0.offset[0]) / c0.zoom, (py - H / 2 - c0.offset[1]) / c0.zoom]
  const c1 = zoomBy(c0, 1.7, W, H, px, py)
  const after = [(px - W / 2 - c1.offset[0]) / c1.zoom, (py - H / 2 - c1.offset[1]) / c1.zoom]
  assert.ok(Math.abs(before[0] - after[0]) < 1e-6 && Math.abs(before[1] - after[1]) < 1e-6)
  assert.equal(zoomBy(c1, 100, W, H).zoom, ZOOM_MAX)
  assert.equal(zoomBy(c1, 0.0001, W, H).zoom, ZOOM_MIN)
})

test("a flick carries on, slows and stops; its speed is capped", () => {
  let c = fling(newCamera(), 2000, 0)
  assert.ok(moving(c))
  const x0 = c.offset[0]
  c = step(c, 1 / 60, W, H)
  assert.ok(c.offset[0] > x0 && c.velocity[0] < 2000)
  for (let i = 0; i < 600 && moving(c); i++) c = step(c, 1 / 60, W, H)
  assert.ok(!moving(c), "it stops")
  assert.ok(Math.hypot(...fling(newCamera(), 1e6, 1e6).velocity) <= MAX_SPEED + 1e-6)
})

test("home glides back to you at zoom 1; glideTo brings someone to the middle", () => {
  let c = zoomBy(pan(newCamera(), 200, 100, W, H), 2, W, H)
  c = home(c)
  for (let i = 0; i < 300 && moving(c); i++) c = step(c, 1 / 60, W, H)
  assert.deepEqual(c.offset, [0, 0]); assert.equal(c.zoom, 1)
  const [x, y] = place(hex("a"), 1)
  c = glideTo(newCamera(), x, y, W, H)
  for (let i = 0; i < 300 && moving(c); i++) c = step(c, 1 / 60, W, H)
  const [sx, sy] = toScreen(x, y, c, W, H)
  assert.ok(Math.abs(sx - W / 2) < 1 && Math.abs(sy - H / 2) < 1)
})

test("only what's on screen is drawn, and a tap picks a face before a dot", () => {
  const nodes = [
    { pk: ME, layer: "me", x: 0, y: 0 },
    { pk: hex("1"), layer: "follow", x: 0.01, y: 0 },
    { pk: hex("2"), layer: "further", x: 0.011, y: 0 },
    { pk: hex("3"), layer: "further", x: 0.9, y: 0.3 }, // far off screen at zoom 1
  ]
  const c = newCamera()
  const drawn = visible(nodes, c, W, H)
  assert.deepEqual(drawn.map(d => d.node.pk), [ME, hex("1"), hex("2")])
  // Right on the dot, which sits under the edge of the face: the face is what was meant.
  const [fx, fy] = toScreen(0.011, 0, c, W, H)
  assert.equal(hit(drawn, fx, fy, 1).pk, hex("1"))
  assert.equal(hit(drawn, 5, 5, 1), null)
})

test("drawing a big web looks at every node once and keeps only the visible: 20,000 nodes in a few ms", () => {
  const nodes = Array.from({ length: 20000 }, (_, i) => { const pk = hex("b", i * 7); const [x, y] = place(pk, 1 + (i % 3)); return { pk, layer: "further", x, y } })
  const t = performance.now()
  const drawn = visible(nodes, newCamera(), W, H)
  assert.ok(performance.now() - t < 50)
  assert.ok(drawn.length < nodes.length / 5, `${drawn.length} on screen`)
})

test("follows' faces are spread so they don't pile up, stay in their zone, and land the same way every time", () => {
  const follows = Array.from({ length: 800 }, (_, i) => hex("a", i * 15485863))
  const web = { me: ME, follows, extended: [], further: [] }
  const a = layout(web, []).filter(n => n.layer === "follow")
  let closest = Infinity
  for (let i = 0; i < a.length; i++) for (let j = i + 1; j < a.length; j++) closest = Math.min(closest, Math.hypot(a[i].x - a[j].x, a[i].y - a[j].y))
  assert.ok(closest > FACE_ROOM * 0.9, `closest pair ${closest} vs room ${FACE_ROOM}`)
  for (const n of a) { const r = Math.hypot(n.x, n.y); assert.ok(r >= ZONES[1].inner - 1e-9 && r <= ZONES[1].outer + 1e-9) }
  const b = layout({ ...web, follows: [...follows].reverse() }, []).filter(n => n.layer === "follow")
  const byPk = new Map(b.map(n => [n.pk, n]))
  for (const n of a) { const m = byPk.get(n.pk); assert.ok(Math.abs(n.x - m.x) < 1e-12 && Math.abs(n.y - m.y) < 1e-12, "order doesn't matter") }
  // Two people at the very same spot are still pulled apart.
  const twins = [{ pk: hex("1"), x: 0.3, y: 0 }, { pk: hex("2"), x: 0.3, y: 0 }]
  spread(twins, 0.02, 0.06, 0.64)
  assert.ok(Math.hypot(twins[0].x - twins[1].x, twins[0].y - twins[1].y) >= 0.02 * 0.99)
})
