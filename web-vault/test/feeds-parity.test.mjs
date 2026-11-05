// Feed parity rows #20 (Global's Web of Trust / Everyone shield) and #21 (Popular's audience and rank line), and #28
// (New Highlight, kind 9802). iPhone as spec: TrustScopeLock.swift, FeedView+TrustScope.swift, PopularRanking.swift,
// PopularRankControls.swift, HighlightPageLink.swift, HighlightShareTags.swift.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { everyoneOn, setEveryone, everyoneLocked, unlockText, everyoneShows, EVERYONE_WARNING, FOLLOWS_NEEDED } from "../src/net/global-trust.js"
import { fetchStrangerFeed, liveFilters, liveKeeps, trustScoped, feedKey, withScope } from "../src/net/feeds.js"
import { AUDIENCES, audienceKeeps, popularRanks, rankScore, scoreNotes } from "../src/net/popular.js"
import { checkLink, highlightTags, highlightComplete, emptyHighlight, HIGHLIGHT_KIND } from "../src/screens/compose/highlight.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const pk = c => c.repeat(64)
const note = (id, pubkey, tags = []) => ({ id, pubkey, kind: 1, created_at: 1000, tags, content: id })
const swift = f => readFileSync(new URL(`../../HavenApp/HavenApp/${f}`, import.meta.url), "utf8")

test("#20 Everyone: off by default, kept on this browser, locked under 5 follows, the phone's words", () => {
  const s = store()
  assert.equal(everyoneOn(s), false)
  setEveryone(true, s); assert.equal(everyoneOn(s), true)
  const me = pk("a"), four = ["1", "2", "3", "4"].map(pk)
  assert.equal(FOLLOWS_NEEDED, 5)
  assert.equal(everyoneLocked([...four, me], me), true, "yourself doesn't count")
  assert.equal(everyoneLocked([...four, pk("5")], me), false)
  assert.equal(everyoneLocked(four, me, true), false, "never locks a choice already made")
  assert.equal(unlockText(four, me), "Follow 1 more person to unlock Everyone")
  assert.equal(unlockText([], me), "Follow 5 more people to unlock Everyone")
  assert.ok(swift("Models/TrustScopeLock.swift").includes("static let followsNeeded = 5"))
  assert.ok(swift("Views/Feed/FeedView+RootContent.swift").includes(EVERYONE_WARNING.text))
})

test("#20 Everyone reads Global unfiltered (never replies) and keys the feed apart; the web of trust is the default", async () => {
  const s = store()
  const g = withScope({ mode: "global" }, s)
  assert.equal(g.everyone, undefined); assert.equal(trustScoped(g), true); assert.equal(feedKey(g), "global")
  setEveryone(true, s)
  const e = withScope({ mode: "global" }, s)
  assert.equal(e.everyone, true); assert.equal(trustScoped(e), false); assert.equal(feedKey(e), "global:everyone")
  assert.equal(feedKey(withScope({ mode: "media", scope: "global" }, s)), "media:global:everyone")
  assert.deepEqual(withScope({ mode: "media", scope: "following" }, s), { mode: "media", scope: "following" }, "Following never takes the shield")
  const stranger = note("n1", pk("9")), reply = note("n2", pk("8"), [["e", "b".repeat(64), "", "reply"]])
  let asked = []
  const got = await fetchStrangerFeed(e, ["wss://r"], { query: async (r, f) => { asked.push(f); return [stranger, reply] } })
  assert.deepEqual(got.map(n => n.id), ["n1"])
  assert.equal(asked.length, 1); assert.equal(asked[0].authors, undefined, "one open ask, no trusted-authors filter")
  assert.deepEqual(await fetchStrangerFeed(g, ["wss://r"], { query: async () => [stranger] }), [], "the web of trust without a web shows nothing, as before")
  assert.deepEqual(liveFilters(e), [{ kinds: asked[0].kinds }])
  assert.equal(liveKeeps(e, stranger), true); assert.equal(liveKeeps(e, reply), false); assert.equal(everyoneShows(reply), false)
})

test("#20 the shield sits in Global's toolbar and asks first", () => {
  const screen = readFileSync(new URL("../src/screens/FeedScreen.jsx", import.meta.url), "utf8")
  assert.match(screen, /shield=\{global \? \{ everyone: !!choice\.everyone, locked: everyoneLocked\(follows, ctx\.session\?\.pubkey\) \} : null\}/)
  assert.match(screen, /else setShieldAsk\(everyoneLocked\(follows, ctx\.session\?\.pubkey\) \? "lock" : "warn"\)/)
  assert.match(screen, /const proceedEveryone = \(\) => \{ setShieldAsk\(null\); setEveryone\(true\); pick\(\{ \.\.\.choice, everyone: true \}\) \}/)
})

test("#21 Popular: who it ranks, and ranks renumbered in the order shown", () => {
  assert.deepEqual(AUDIENCES.map(a => a[1]), ["Everyone", "People you follow", "People you don't follow"])
  const follows = new Set([pk("1")])
  assert.equal(audienceKeeps(note("a", pk("1")), "follows", follows), true)
  assert.equal(audienceKeeps(note("a", pk("1")), "nonFollows", follows), false)
  assert.equal(audienceKeeps(note("b", pk("2")), "all", follows), true)
  const scores = new Map([["x", 30], ["y", 20], ["z", 10]])
  assert.deepEqual([...popularRanks(["y", "reply", "z"], scores)], [["y", 1], ["z", 2]], "a narrower audience renumbers from #1; unscored take no number")
  assert.equal(rankScore(1234), "1.2k"); assert.equal(rankScore(42.4), "42")
  const t = new Map([["n", new Map([[pk("4"), 1], [pk("5"), 2], [pk("6"), 3]])]])
  const out = new Map()
  scoreNotes([note("n", pk("7"))], t, { now: 1000, scores: out })
  assert.equal(out.get("n"), 6, "scoreNotes hands its scores on")
  const rows = readFileSync(new URL("../src/components/FeedRows.jsx", import.meta.url), "utf8")
  assert.equal((rows.match(/<Ranked id=/g) ?? []).length, 3, "the rank line in every layout")
})

test("#28 New Highlight: the phone's link check and NIP-84 tags", () => {
  assert.equal(HIGHLIGHT_KIND, 9802)
  assert.equal(checkLink(""), "")
  assert.equal(checkLink("example.com/post"), "https://example.com/post")
  assert.equal(checkLink("http://a.b/c"), "http://a.b/c")
  for (const bad of ["not a link", "ftp://a.b", "localhost", "//a.b", "a.", ".a"]) assert.equal(checkLink(bad), null, bad)
  assert.deepEqual(highlightTags({ passage: " Words ", link: "https://a.b/c", comment: " nice " }), [["r", "https://a.b/c", "source"], ["comment", "nice"], ["alt", 'Highlight: "Words"']])
  assert.deepEqual(highlightTags({ passage: "W", link: "", comment: "" }), [["alt", 'Highlight: "W"']])
  assert.equal(highlightComplete({ ...emptyHighlight(), passage: "w" }), true)
  assert.equal(highlightComplete({ ...emptyHighlight(), passage: "w", link: "nope nope" }), false, "a bad link waits until fixed or cleared")
  assert.equal(highlightComplete(emptyHighlight()), false)
  const kinds = readFileSync(new URL("../src/screens/compose/ComposeKinds.jsx", import.meta.url), "utf8")
  assert.match(kinds, /\["highlight", "Highlight"\]/)
  assert.match(readFileSync(new URL("../src/screens/ComposeScreen.jsx", import.meta.url), "utf8"), /if \(type === "highlight"\) return <HighlightCompose ctx=\{props\.ctx\} \/>/)
  const link = readFileSync(new URL("../../HavenApp/HavenApp/SharePortalKit/HighlightPageLink.swift", import.meta.url), "utf8")
  assert.ok(link.includes('"That doesn\'t look like a web address."'))
})

test("#28 the page link is a text field: the browser's own URL check would block \"example.com/essay\", which the phone accepts", () => {
  const c = readFileSync(new URL("../src/screens/compose/HighlightCompose.jsx", import.meta.url), "utf8")
  assert.match(c, /<input type="text" inputmode="url" class="kind-field" placeholder=\{LINK_PLACEHOLDER\}/)
  assert.match(c, /<form id="highlight-form" class="kind-form" noValidate onSubmit=\{post\}>/)
})
