// Web Settings batch 1 (Tidy's gap list 11-21): Who Can Reach You, Feed switches + Reload, Show message text,
// Translation, Reveal Key. The logic each row drives; the rows themselves are plain switches over these.
import { test } from "node:test"
import assert from "node:assert/strict"
import { minFollowers, setMinFollowers, refreshChoice, setRefreshChoice, trustRefreshMs, onTrustSettings, REFRESH_CHOICES } from "../src/net/trust-settings.js"
import { MIN_FOLLOWERS, webLayers } from "../src/net/web-gate.js"
import { loadFilters, saveFilters, onFilters } from "../src/net/feed-filters.js"
import { askFeedReload, takeFeedReload } from "../src/net/feed-reload.js"
import { dmNotices, showDmText, setShowDmText, dmPreview } from "../src/net/dm-notify.js"
import { fileLink } from "../src/net/dm-file.js"
import { translateOn, setTranslateOn, translateTo, setTranslateTo, translateTarget, pickerList } from "../src/net/translate-prefs.js"
import { canReveal } from "../src/components/reveal-key.js"

const mem = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const hex = n => n.toString(16).padStart(64, "0")

test("Minimum Followers: default is the gate's bar, clamped 0-100, and it moves who is in the web", () => {
  const s = mem()
  assert.equal(minFollowers(s), MIN_FOLLOWERS)
  assert.equal(setMinFollowers(3, s), 3)
  assert.equal(setMinFollowers(500, s), 100)
  assert.equal(setMinFollowers(-4, s), 0)
  // 12 follows; X is followed by 3 of them. Bar 10: X is hop 3. Bar 3: X is in the web.
  const follows = Array.from({ length: 12 }, (_, i) => hex(i + 1)), X = hex(999)
  const lists = new Map(follows.map((f, i) => [f, { tags: i < 3 ? [["p", X]] : [] }]))
  assert.ok(webLayers({ follows, lists, minFollowers: MIN_FOLLOWERS }).loose.has(X))
  assert.ok(webLayers({ follows, lists, minFollowers: 3 }).web.has(X))
})

test("Refresh Trust List: the phone's four choices, default every day, an unknown id ignored, listeners told", () => {
  const s = mem()
  assert.deepEqual(REFRESH_CHOICES.map(c => c.label), ["Every hour", "Every 12 hours", "Every day", "Every week"])
  assert.equal(refreshChoice(s), "24h")
  assert.equal(trustRefreshMs(s), 24 * 3600_000)
  let told = 0
  const off = onTrustSettings(() => told++)
  assert.equal(setRefreshChoice("1h", s), "1h")
  assert.equal(trustRefreshMs(s), 3600_000)
  assert.equal(setRefreshChoice("6h", s), "1h", "not a choice: unchanged")
  off()
  assert.equal(told, 1)
})

test("Feed switches: a save tells the Feed on screen; Reload Feed is taken once", () => {
  const s = mem()
  let heard = 0
  const off = onFilters(() => heard++)
  saveFilters({ ...loadFilters(s), reposts: false }, s)
  off()
  assert.equal(heard, 1)
  assert.equal(loadFilters(s).reposts, false)
  const went = [], sent = []
  askFeedReload({ go: h => went.push(h), dispatch: e => sent.push(e.type) })
  assert.deepEqual([went, sent], [["#/feed"], ["nv:feed-refresh"]])
  assert.equal(takeFeedReload(), true)
  assert.equal(takeFeedReload(), false)
})

test("Show message text: off by default says only who; on shows the text, never a file's key", () => {
  const s = mem()
  const ME = hex(1), C = hex(2)
  const msg = (id, content) => [id, { id, from: C, peer: C, content, at: 200 }]
  const nameOf = () => "Carol"
  assert.equal(showDmText(s), false)
  const plain = dmNotices(new Map([msg("a", "hi   there\nfriend")]), ME, { mark: 100, nameOf, now: 1000 })
  assert.deepEqual([plain.notices[0].title, plain.notices[0].body], ["New message", "From Carol"])
  assert.equal(setShowDmText(true, s), true)
  const shown = dmNotices(new Map([msg("a", "hi   there\nfriend")]), ME, { mark: 100, nameOf, now: 1000, showText: true })
  assert.deepEqual([shown.notices[0].title, shown.notices[0].body], ["Carol", "hi there friend"])
  const link = fileLink("https://blossom.example/abc", { key: hex(7), nonce: "0".repeat(24) })
  const file = dmNotices(new Map([msg("f", link)]), ME, { mark: 100, nameOf, now: 1000, showText: true })
  assert.equal(file.notices[0].body, "Sent a file")
  assert.ok(!JSON.stringify(file.notices).includes(hex(7)), "the file key never goes in a notification")
  const mixed = dmNotices(new Map([msg("g", `look ${link} ok`)]), ME, { mark: 100, nameOf, now: 1000, showText: true })
  assert.equal(mixed.notices[0].body, "look a file ok", "a file link among other words loses its key too (Tron)")
    assert.equal(dmPreview("x".repeat(200)).length, 160)
  assert.equal(setShowDmText(false, s), false)
})

test("Translation: on by default, Translate To falls back to the browser's language", () => {
  const s = mem(), nav = { language: "de-AT", languages: ["de-AT", "en-US"] }
  assert.equal(translateOn(s), true)
  assert.equal(translateTarget(s, nav), "de")
  assert.equal(setTranslateTo("ja", s), "ja")
  assert.equal(translateTarget(s, nav), "ja")
  assert.equal(setTranslateTo("<script>", s), "")
  assert.equal(setTranslateOn(false, s), false)
  assert.equal(translateTo(s), "", "the bad code was dropped")
  assert.deepEqual(pickerList(nav).slice(0, 3), ["de", "en", "es"])
})

test("Reveal Key: only accounts whose key is kept in this browser", () => {
  assert.equal(canReveal({ method: "local", ncryptsec: "ncryptsec1abc" }), true)
  assert.equal(canReveal({ method: "local" }), false)
  assert.equal(canReveal({ method: "nip07", ncryptsec: "ncryptsec1abc" }), false)
  assert.equal(canReveal({ method: "nip46" }), false)
  assert.equal(canReveal(null), false)
})
