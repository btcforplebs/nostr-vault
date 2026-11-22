// The feeds on the one gate (feed-gate.js): reach per feed, the Everyone shield and list feeds, and one pass that
// shows inside + rationed hop 3, folds outside and hides blocked.
import test from "node:test"
import assert from "node:assert/strict"
import { gateFeed, feedReach, loadReach, saveReach, REACH_FEEDS } from "../src/net/feed-gate.js"
import { gateWeb, REACHES } from "../src/net/web-gate.js"
import { muteSet } from "../src/net/blocks.js"

const pk = n => n.toString(16).padStart(64, "0")
const ME = pk(1), F = pk(2), NEAR = pk(3), STRANGER = pk(4), BAD = pk(5)
let seq = 100
const note = (pubkey, tags = []) => ({ id: pk(seq++), kind: 1, pubkey, created_at: seq, content: "x", tags })
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const web = gateWeb({ own: [ME], web: [F], loose: [NEAR], blocked: muteSet([BAD]) })

test("defaults: every web feed reaches your web but Underrated, one step out by design; a choice is kept per feed", () => {
  const s = store()
  for (const [id] of REACH_FEEDS) assert.equal(loadReach(id, s), id === "underrated" ? "webAndHop3" : "web", id)
  saveReach("popular", "webAndHop3", s)
  assert.equal(loadReach("popular", s), "webAndHop3")
  assert.equal(loadReach("global", s), "web")
  assert.equal(loadReach("underrated", s), "webAndHop3", "Underrated's default, for when the web has one")
  saveReach("global", "nonsense", s)
  assert.equal(loadReach("global", s), "web")
})

test("feedReach: Everyone shield and list feeds reach everyone; otherwise the setting", () => {
  const s = store()
  saveReach("hashtag", "webAndHop3", s)
  assert.equal(feedReach({ mode: "global", everyone: true }, s), "everyone")
  assert.equal(feedReach({ mode: "media", scope: "global", everyone: true }, s), "everyone")
  assert.equal(feedReach({ mode: "global" }, s), "web")
  assert.equal(feedReach({ mode: "list", list: "x" }, s), "everyone")
  assert.equal(feedReach({ mode: "hashtag", tag: "a" }, s), "webAndHop3")
})

test("gateFeed: inside shows, outside folds, blocked goes, order kept", () => {
  const notes = [note(F), note(STRANGER), note(BAD), note(ME), note(NEAR)]
  const { shown, outside } = gateFeed(notes, web)
  assert.deepEqual(shown.map(n => n.pubkey), [F, ME])
  assert.deepEqual(outside.map(n => n.pubkey), [STRANGER, NEAR])
})

test("gateFeed: hop 3 shows on webAndHop3, a hop-3 reply does not; everyone shows strangers but never the blocked", () => {
  const top = note(NEAR), reply = note(NEAR, [["e", pk(9), "", "reply"]])
  const hop = gateFeed([note(F), top, reply], web, { reach: "webAndHop3" })
  assert.deepEqual(hop.shown.map(n => n.id), [hop.shown[0].id, top.id])
  assert.equal(hop.outside.length, 0, "a rationed-out hop-3 note is dropped, not folded")
  const all = gateFeed([note(STRANGER), note(BAD)], web, { reach: "everyone" })
  assert.deepEqual(all.shown.map(n => n.pubkey), [STRANGER])
  assert.equal(all.outside.length, 0)
})

test("gateFeed: a reply to a blocked person's note in the same list is blocked", () => {
  const theirs = note(BAD)
  const answer = note(F, [["e", theirs.id, "", "reply"]])
  assert.deepEqual(gateFeed([theirs, answer], web).shown, [])
  assert.deepEqual(gateFeed(null, web), { shown: null, outside: [] })
})

// The saved words are a format (iPhone/Mac twin: FeedGateTests.testSavedReachWordsNeverChange): renaming the code must
// still read what an older build wrote to this browser, and write what an older build reads.
test("saved reach words never change: the key, the words, and a round trip through raw storage", () => {
  assert.deepEqual([...REACHES], ["web", "webAndHop3", "everyone"])
  const s = store()
  s.setItem("nv-feed-reach", JSON.stringify({ popular: "webAndHop3", underrated: "web" }))
  assert.equal(loadReach("popular", s), "webAndHop3", "a Popular feed saved one hop out by an older build still reads one hop out")
  assert.equal(loadReach("underrated", s), "web")
  const fresh = store()
  saveReach("popular", loadReach("underrated", fresh), fresh)
  assert.equal(fresh.getItem("nv-feed-reach"), JSON.stringify({ popular: "webAndHop3" }), "and is written the way an older build reads it")
})
