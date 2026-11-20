// Live now (src/desktop/space/live-now.js): the Your space panel's streams are the Live feed's Following, newest first,
// with the same id and empty lines as the iPad (HavenApp/Models/LiveNow.swift, LiveNowTests).
import test from "node:test"
import assert from "node:assert/strict"
import { liveNow, rowsOf, emptyLine, forgetLiveNow, LIVE_NOW_ID, MAX_ROWS, OVERLAP } from "../src/desktop/space/live-now.js"
import { STALE_AFTER } from "../src/readers/live.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"

const friend = "a".repeat(64), service = "b".repeat(64), stranger = "c".repeat(64), other = "d".repeat(64)
const now = 1_800_000_000
const hls = ["streaming", "https://cdn.example/live/index.m3u8"]
const ev = (id, pubkey, d, at, extra) => ({ id, kind: 30311, pubkey, created_at: at, tags: [["d", d], ...extra] })
/** A relay that answers every filter with the same events (the panel dedupes across the two asks). */
const relay = evs => async (_relays, filter) => evs.filter(e => !filter.authors || filter.authors.includes(e.pubkey) || e.tags.some(t => t[0] === "p" && filter["#p"]?.includes(t[1])))
test.beforeEach(() => forgetLiveNow())
const look = (evs, opts = {}) => liveNow({ me: "e".repeat(64), follows: [friend, other], readRelays: [], blocked: new Set(), query: relay(evs), now, ...opts })

test("the panel id is shared with the iPad and registered", () => {
  assert.equal(LIVE_NOW_ID, "live-now")
  assert.ok(PANEL_IDS.includes(LIVE_NOW_ID))
})

test("live streams of follows, newest first", async () => {
  const list = await look([ev("old", friend, "a", now - 600, [["status", "live"], hls]), ev("new", other, "b", now - 60, [["status", "live"], hls])])
  assert.deepEqual(list.map(s => s.id), ["new", "old"])
})

test("strangers and followed guests are left out; a service stream counts for its Host", async () => {
  const list = await look([
    ev("stranger", stranger, "s", now - 60, [["status", "live"], hls]),
    ev("guest", stranger, "g", now - 60, [["status", "live"], hls, ["p", friend, "", "Speaker"]]),
    ev("svc", service, "v", now - 60, [["status", "live"], hls, ["p", friend, "", "Host"]]),
  ])
  assert.deepEqual(list.map(s => s.id), ["svc"])
  assert.equal(list[0].host, friend)
})

test("a block on the host or the signer hides it", async () => {
  const evs = [ev("svc", service, "v", now - 60, [["status", "live"], hls, ["p", friend, "", "Host"]])]
  assert.deepEqual(await look(evs, { blocked: new Set([friend]) }), [])
  assert.deepEqual(await look(evs, { blocked: new Set([service]) }), [])
})

test("ended, stale, unplayable, past ends and planned are not live", async () => {
  const list = await look([
    ev("ended", friend, "x", now - 30, [["status", "ended"], hls]),
    ev("live", friend, "x", now - 300, [["status", "live"], hls]),
    ev("stale", friend, "a", now - 2 * 3600, [["status", "live"], hls]),
    ev("noURL", friend, "b", now - 60, [["status", "live"]]),
    ev("web", friend, "c", now - 60, [["status", "live"], ["streaming", "https://youtube.com/live/x"]]),
    ev("pastEnds", friend, "e", now - 60, [["status", "live"], hls, ["ends", String(now - 1)]]),
    ev("planned", friend, "f", now - 60, [["status", "planned"], hls]),
  ])
  assert.deepEqual(list, [])
})

test("following nobody asks nothing and shows nothing", async () => {
  let asked = 0
  const list = await liveNow({ me: "e".repeat(64), follows: [], readRelays: [], blocked: new Set(), query: async () => { asked++; return [] }, now })
  assert.deepEqual(list, [])
  assert.equal(asked, 0)
})

test("rows: the first MAX_ROWS and how many more", () => {
  const many = Array.from({ length: MAX_ROWS + 2 }, (_, i) => ({ id: String(i) }))
  assert.deepEqual(rowsOf(many).rows.map(s => s.id), ["0", "1", "2", "3", "4"])
  assert.equal(rowsOf(many).more, 2)
  assert.deepEqual(rowsOf([]), { rows: [], more: 0 })
})

test("the calm empty lines match the iPad", () => {
  assert.equal(emptyLine(true), "Nobody you follow is live right now.")
  assert.equal(emptyLine(false), "Follow people to see when they go live.")
})

test("the first look asks only for the last hour, each repeat only since the last look", async () => {
  const asked = []
  const query = async (_r, f) => { asked.push(f.since); return [] }
  const at = t => liveNow({ me: "e".repeat(64), follows: [friend], readRelays: [], blocked: new Set(), query, now: t })
  await at(now)
  await at(now + 120)
  assert.deepEqual(asked, [now - STALE_AFTER - OVERLAP, now - STALE_AFTER - OVERLAP, now - OVERLAP, now - OVERLAP])
})

test("a stream heard on an earlier look stays until it ends or goes stale; a new follow list starts over", async () => {
  let answer = [ev("a1", friend, "a", now - 60, [["status", "live"], hls])]
  const query = (r, f) => relay(answer)(r, f)
  const at = (t, follows = [friend]) => liveNow({ me: "e".repeat(64), follows, readRelays: [], blocked: new Set(), query, now: t })
  assert.deepEqual((await at(now)).map(s => s.id), ["a1"])
  answer = [ev("b1", friend, "b", now + 60, [["status", "live"], hls])]
  assert.deepEqual((await at(now + 120)).map(s => s.id), ["b1", "a1"], "held and new merge")
  answer = [ev("a2", friend, "a", now + 200, [["status", "ended"], hls])]
  assert.deepEqual((await at(now + 240)).map(s => s.id), ["b1"], "an end replaces its live announcement")
  answer = []
  assert.deepEqual(await at(now + 60 + STALE_AFTER + 1), [], "not republished for an hour: gone")
  let since = null
  await liveNow({ me: "e".repeat(64), follows: [friend, other], readRelays: [], blocked: new Set(), query: async (_r, f) => { since = f.since; return [] }, now: now + 5000 })
  assert.equal(since, now + 5000 - STALE_AFTER - OVERLAP)
})
