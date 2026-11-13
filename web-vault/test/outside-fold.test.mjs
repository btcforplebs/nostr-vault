// Stricter web of trust (Logen 2026-11-13 "go all"): A) Notifications fold likes and reposts from outside your web into
// one line; C) Global's Everyone banner wording. Search's fold (B) is in search.test.mjs.
import test from "node:test"
import assert from "node:assert/strict"
import { splitOutsideLikes, outsideCount, outsideLabel, FOLDED_TYPES } from "../src/net/outside-fold.js"
import { groupNotifications } from "../src/net/notifications.js"
import { EVERYONE_BANNER } from "../src/net/global-trust.js"

const ME = "1".repeat(64), FRIEND = "2".repeat(64), WEB = "3".repeat(64), S1 = "4".repeat(64), S2 = "5".repeat(64)
const NOTE = "a".repeat(64)
let n = 0
const ev = (kind, pubkey, extra = {}) => ({ id: (++n).toString(16).padStart(64, "0"), kind, pubkey, created_at: 100 + n, content: "", tags: [["e", NOTE], ["p", ME]], ...extra })
const ids = list => list.map(e => e.id)

test("likes and reposts from outside the web fold; inside ones and everything else stay", () => {
  const like = ev(7, S1, { content: "+" }), repost = ev(6, S2), friendLike = ev(7, FRIEND), webRepost = ev(6, WEB)
  const reply = ev(1, S1, { content: "hi" }), follow = ev(3, S2, { tags: [["p", ME]] })
  const { inside, outside } = splitOutsideLikes([like, repost, friendLike, webRepost, reply, follow], ME,
    { trusted: new Set([FRIEND, WEB]), follows: [FRIEND] })
  assert.deepEqual(ids(outside), ids([like, repost]))
  assert.deepEqual(ids(inside), ids([friendLike, webRepost, reply, follow]))
})

test("zaps from strangers keep their rows: only reactions and reposts fold", () => {
  assert.deepEqual([...FOLDED_TYPES].sort(), ["reaction", "repost"])
})

test("the whitelist counts as inside", () => {
  const like = ev(7, S1)
  const { outside } = splitOutsideLikes([like], ME, { trusted: new Set(), whitelist: new Set([S1]) })
  assert.deepEqual(outside, [])
})

test("while the web loads (trusted null) only you and your follows are inside: a web like folds until it arrives", () => {
  const friend = ev(7, FRIEND), web = ev(7, WEB)
  const loading = splitOutsideLikes([friend, web], ME, { trusted: null, follows: [FRIEND] })
  assert.deepEqual(ids(loading.inside), ids([friend]))
  assert.deepEqual(ids(loading.outside), ids([web]))
  const loaded = splitOutsideLikes([friend, web], ME, { trusted: new Set([FRIEND, WEB]), follows: [FRIEND] })
  assert.deepEqual(loaded.outside, [])
})

test("an empty web fails closed: every stranger's like folds", () => {
  const { outside } = splitOutsideLikes([ev(7, S1), ev(6, S2)], ME, { trusted: new Set(), follows: [] })
  assert.equal(outside.length, 2)
})

test("N counts each person once per row", () => {
  const rows = groupNotifications([ev(7, S1), ev(7, S1, { content: "🔥" }), ev(7, S2), ev(6, S1)], ME)
  assert.equal(outsideCount(rows), 3) // S1 and S2 liked the note, S1 reposted it
  assert.equal(outsideCount([]), 0)
  assert.equal(outsideCount(null), 0)
})

test("the fold line reads Show / Hide N from outside your web", () => {
  assert.equal(outsideLabel(4, false), "Show 4 from outside your web")
  assert.equal(outsideLabel(1, true), "Hide 1 from outside your web")
})

test("the Everyone banner says what it means and how to go back", () => {
  assert.match(EVERYONE_BANNER.text, /^Everyone is on/)
  assert.match(EVERYONE_BANNER.text, /outside your web/)
  assert.equal(EVERYONE_BANNER.back, "Back to your web")
})
