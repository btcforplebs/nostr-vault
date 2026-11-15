// One plan step 4: today's Your space panels as widget napplets. The shell's answers (widget-answers.js) hand a card
// only what it draws; the widget list matches the panel ids; the release manifests carry the surface tag columns.js
// reads; and each widget napplet asks only for the shell-answered intents WidgetCard.jsx serves.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { surfaceAnswer, fitHeight, countOf, liveNowData, thisDayData, noteRoute, MIN_FIT_PX } from "../src/desktop/space/widget-answers.js"
import { FIRST_PARTY_LIST } from "../src/napplet/first-party-list.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"
import { manifestTemplate } from "../tools/napplet-release.mjs"
import { surfaceOf, SIZE_PX } from "../src/desktop/space/columns.js"
import { MAX_ROWS } from "../src/desktop/space/live-now.js"

const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")
const H = c => c.repeat(64)
const WIDGETS = FIRST_PARTY_LIST.filter(n => n.widget)

test("widgets: each draws one of our panels, once, is a pane (never in the Apps list) and has sizes columns.js knows", () => {
  assert.ok(WIDGETS.length >= 2)
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
  const served = new Set(["napplet:shell/surface", "napplet:card/height", "napplet:card/count", "napplet:space/livenow", "napplet:live/open", "napplet:space/thisday", "napplet:note/show"])
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
