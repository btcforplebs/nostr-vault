// One plan step 4: today's Your space panels as widget napplets. The shell's answers (widget-answers.js) hand a card
// only what it draws; the widget list matches the panel ids; the release manifests carry the surface tag columns.js
// reads; and each widget napplet asks only for the shell-answered intents WidgetCard.jsx serves.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { surfaceAnswer, fitHeight, countOf, liveNowData, thisDayData, noteRoute, openRoute, vaultData, devicesData, messagesData, wotData, MIN_FIT_PX } from "../src/desktop/space/widget-answers.js"
import { FIRST_PARTY_LIST } from "../src/napplet/first-party-list.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"
import { manifestTemplate } from "../tools/napplet-release.mjs"
import { surfaceOf, SIZE_PX } from "../src/desktop/space/columns.js"
import { MAX_ROWS } from "../src/desktop/space/live-now.js"

const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")
const H = c => c.repeat(64)
const WIDGETS = FIRST_PARTY_LIST.filter(n => n.widget)

test("widgets: each draws one of our panels, once, is a pane (never in the Apps list) and has sizes columns.js knows", () => {
  assert.deepEqual(WIDGETS.map(n => n.card).sort(), [...PANEL_IDS].sort(), "all six of today's cards (Logen's call 3: six separate cards)")
  const cards = WIDGETS.map(n => n.card)
  assert.equal(new Set(cards).size, cards.length)
  for (const n of WIDGETS) {
    assert.ok(PANEL_IDS.includes(n.card), `${n.dTag} draws a real panel id`)
    assert.equal(n.pane, true)
    assert.deepEqual(n.widget.filter(s => !["S", "M", "L"].includes(s)), [])
  }
})

test("widgets: the release manifest carries ['surface','widget',...sizes] and columns.js reads it back", () => {
  for (const n of WIDGETS) {
    const t = manifestTemplate(n, "<!doctype html>")
    assert.deepEqual(t.tags.find(x => x[0] === "surface"), ["surface", "widget", ...n.widget])
    assert.deepEqual(surfaceOf(t), { widget: true, sizes: n.widget })
  }
  const plain = FIRST_PARTY_LIST.find(n => !n.widget && !n.sample)
  assert.equal(manifestTemplate(plain, "x").tags.some(x => x[0] === "surface"), false, "a page napplet has no surface tag")
})

test("widgets: each napplet asks only for intents the shell answers, and reads nothing else", () => {
  const served = new Set(["napplet:shell/surface", "napplet:card/height", "napplet:card/count", "napplet:space/livenow", "napplet:live/open", "napplet:space/thisday", "napplet:note/show",
    "napplet:space/vault", "napplet:space/messages", "napplet:space/devices", "napplet:space/wot", "napplet:space/open"])
  for (const n of WIDGETS) {
    const html = read(`napplets/${n.file}/index.html`)
    const asked = [...html.matchAll(/"(napplet:[a-z]+\/[a-z]+)"/g)].map(m => m[1])
    assert.ok(asked.length, n.file)
    for (const a of asked) assert.ok(served.has(a), `${n.file} asks ${a}`)
    assert.doesNotMatch(html, /\bn\.(outbox|relay|identity|storage|dm|blossom)\b/, `${n.file} reads only through the shell's answers`)
  }
})

test("surface: size null is the card's own height; fit heights stay between one line and Large", () => {
  assert.deepEqual(surfaceAnswer(undefined, "right"), { surface: "widget", size: null, side: "right" })
  assert.deepEqual(surfaceAnswer("M", "left"), { surface: "widget", size: "M", side: "left" })
  assert.equal(fitHeight(10), MIN_FIT_PX)
  assert.equal(fitHeight(5000), SIZE_PX.L)
  assert.equal(fitHeight(201.6), 202)
  assert.equal(fitHeight("x"), null)
  assert.equal(countOf(3), 3)
  assert.equal(countOf(-1), 0)
  assert.equal(countOf(2.5), 0)
})

test("live now: only the drawn rows, each host's name and an https picture; the same empty line as the panel", () => {
  const streams = Array.from({ length: MAX_ROWS + 2 }, (_, i) => ({ address: `30311:${H(String(i))}:s`, host: H(String(i)), title: i ? `Show ${i}` : "", url: "https://hls.example/x.m3u8", event: { secret: true } }))
  const profiles = { [H("0")]: { name: "Zero", picture: "https://p.example/0.png" }, [H("1")]: { name: "One", picture: "http://p.example/1.png" } }
  const d = liveNowData(streams, pk => profiles[pk], true)
  assert.equal(d.count, MAX_ROWS + 2)
  assert.equal(d.more, 2)
  assert.equal(d.rows.length, MAX_ROWS)
  assert.deepEqual(d.rows[0], { address: streams[0].address, host: H("0"), title: "", name: "Zero", picture: "https://p.example/0.png" })
  assert.equal(d.rows[1].picture, "", "no plain-http pictures")
  assert.ok(d.rows.every(r => !("event" in r) && !("url" in r)), "the stream's event and link stay in the shell")
  assert.equal(liveNowData([], () => null, false).empty, "Follow people to see when they go live.")
})

test("on this day: years with notes only, each note its id, line and time; note/show takes only a note id", () => {
  const ev = { id: H("e"), kind: 1, pubkey: H("a"), created_at: 1_700_000_000, content: "hello there", tags: [["p", H("b")]] }
  assert.deepEqual(thisDayData([{ years: 1, since: 1, notes: [ev] }, { years: 2, since: 1, notes: [] }]),
    [{ label: "1 year ago", notes: [{ id: H("e"), text: "hello there", at: 1_700_000_000 }] }])
  assert.equal(noteRoute(H("e")), `#/thread/${H("e")}`)
  for (const bad of ["#/settings", `${H("e")}x`, H("E"), null, 5]) assert.equal(noteRoute(bad), null)
})

const PROFILES = { [H("a")]: { name: "Ann", picture: "https://x/a.png" }, [H("b")]: { display_name: "Bob", picture: "http://x/b.png" } }
const profileOf = pk => PROFILES[pk]

test("open: a card hands back a row id the shell gave it, never a route; anything else opens nothing", () => {
  const routes = new Map([[H("1"), "#/thread/" + H("1")], ["globe", "#/wot"]])
  assert.equal(openRoute(routes, H("1")), "#/thread/" + H("1"))
  assert.equal(openRoute(routes, "globe"), "#/wot")
  assert.equal(openRoute(routes, "#/settings"), null)
  assert.equal(openRoute(routes, { id: "globe" }), null)
  assert.equal(openRoute(routes, undefined), null)
})

test("vault: rows carry who, verb, line, time, unread and an https face; the routes stay with the shell", () => {
  const rows = [{ id: "r1", kind: "like", actors: [H("a"), H("b")], preview: "hello", created_at: 100, openId: H("1") }]
  const { data, routes } = vaultData({ rows, unread: new Set(["r1"]), faces: [H("a"), H("b")], facesLine: "2 people lately", fetched: true },
    { profileOf, verbOf: () => "liked your note", whoOf: (a, nameOf) => a.map(nameOf).join(" and "), hrefOf: r => `#/thread/${r.openId}`, textOf: t => t })
  assert.deepEqual(data.rows, [{ id: "r1", who: "Ann and Bob", verb: "liked your note", text: "hello", at: 100, unread: true, name: "Ann", picture: "https://x/a.png" }])
  assert.deepEqual(data.faces, [{ name: "Ann", picture: "https://x/a.png" }, { name: "Bob", picture: "" }], "http pictures never cross")
  assert.equal(routes.get("r1"), `#/thread/${H("1")}`)
  assert.doesNotMatch(JSON.stringify(data), /#\//, "no route is handed to the card")
})

test("devices: null until the first look, then each row's state and line, and the on-the-mesh count", () => {
  assert.deepEqual(devicesData(null, 0, {}), { data: null, onMesh: 0, total: 0 })
  const loaded = { devices: [{ hex: H("c") }, { hex: H("d") }], adverts: new Map(), checked: true }
  const states = { [H("c")]: "online", [H("d")]: "offline" }
  const out = devicesData(loaded, 50, { deviceStatus: (_, __, o) => ({ state: o.checked ? "?" : "x" }), statusLine: s => s.state, deviceName: d => d.hex.slice(0, 2), header: "H" })
  assert.equal(out.total, 2)
  const real = devicesData({ ...loaded, adverts: new Map(Object.entries(states)) }, 50, { deviceStatus: a => ({ state: a }), statusLine: s => `is ${s.state}`, deviceName: d => d.hex.slice(0, 2), header: "H" })
  assert.deepEqual(real.data, { header: "H", rows: [{ id: H("c"), name: "cc", line: "is online", state: "online" }, { id: H("d"), name: "dd", line: "is offline", state: "offline" }] })
  assert.equal(real.onMesh, 1)
  assert.equal(out.data.rows[0].state, "?")
})

test("messages: closed says why; open hands the name and last line only, a stranger's picture waits", () => {
  assert.equal(messagesData({ open: false, note: "", rows: [] }, H("e"), {}).data.status, "Reading your messages…")
  assert.equal(messagesData({ open: false, note: "no signer", rows: [] }, H("e"), {}).data.status, "Your messages can't be read here (no signer).")
  const rows = [{ peer: H("a"), last: { from: H("e"), content: "secret plan", at: 9, id: "x", tags: [] }, unread: 0 }, { peer: H("f"), last: { from: H("f"), content: "hi", at: 8 }, unread: 3 }]
  const { data, routes } = messagesData({ open: true, rows }, H("e"), { profileOf, previewOf: c => c.toUpperCase(), loadPic: pk => pk === H("a") })
  assert.deepEqual(data.rows, [
    { id: H("a"), name: "Ann", picture: "https://x/a.png", text: "You: SECRET PLAN", at: 9, unread: 0 },
    { id: H("f"), name: "ffffffff…", picture: "", text: "HI", at: 8, unread: 3 },
  ])
  assert.equal(data.status, "")
  assert.equal(routes.get(H("f")), `#/dm/${H("f")}`)
  assert.equal(messagesData({ open: true, rows: [] }, H("e"), { profileOf }).data.status, "No messages yet.")
})

test("wot: numbers, status, new faces with their vouch line, globe points to two places; faces and the globe open", () => {
  const { data, routes } = wotData({ counts: { everyone: 10, following: 3, close: 2, extra: 1 }, status: null, fresh: [H("a"), H("b")], faces: [H("a")],
    points: [{ p: [0.123456, -1, 0.5], kind: "new" }], extendedMin: 3 }, { profileOf, vouchOf: () => "3 of your follows" })
  assert.deepEqual(data, { counts: { everyone: 10, following: 3, close: 2 }, status: "", newCount: 2, extendedMin: 3,
    faces: [{ id: H("a"), name: "Ann", picture: "https://x/a.png", title: "3 of your follows" }], points: [{ p: [0.12, -1, 0.5], kind: "new" }] })
  assert.equal(routes.get(H("a")), `#/wot/${H("a")}`)
  assert.equal(routes.get("globe"), "#/wot")
  assert.equal(routes.has(H("b")), false, "only faces drawn open")
  assert.equal(wotData({ counts: null, status: "Loading…", fresh: [], faces: [], points: [] }, { profileOf, vouchOf: () => "" }).data.counts, null)
})

test("a card keeps its header count when a source puts the same one again (the folded Live Vault loop)", async () => {
  const { sameBadge } = await import("../src/desktop/space/widget-answers.js")
  assert.equal(sameBadge(null, null), true)
  assert.equal(sameBadge({ text: "3", label: "3 new" }, { text: "3", label: "3 new" }), true)
  assert.equal(sameBadge({ text: "3", label: "3 new" }, { text: "4", label: "4 new" }), false)
  assert.equal(sameBadge({ text: "3", label: "3 new" }, null), false)
  assert.equal(sameBadge(null, { text: "1", label: "1 new" }), false)
  assert.equal(sameBadge({ text: "1", label: "x", cls: "a" }, { text: "1", label: "x", cls: "b" }), false)
  assert.match(read("src/desktop/space/WidgetCard.jsx"), /setBadgeNow\(was => \(sameBadge\(was, next\) \? was : next\)\)/)
})
