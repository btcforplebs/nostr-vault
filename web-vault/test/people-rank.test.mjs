// The shared people ranker (search plan RESEARCH/NV_SEARCH_PLAN_2026_11_27.md 1a, W2): closeness first (thread, you,
// follows, your web, 3+ steps away, outside), then the name match, trust score, shorter name, pubkey. Blocked people
// never show. Throwaway hex keys, no network.
import test from "node:test"
import assert from "node:assert/strict"
import { foldText, nameMatch, tierOf, isInside, rankPeople, fromRankCopy, TIER } from "../src/net/people-rank.js"
import { shapeResults } from "../src/net/search.js"

const k = c => c.repeat(64)
const [ME, ALT, F, W, D, X, Y, T] = ["a", "b", "c", "d", "e", "f", "1", "2"].map(k)
const profiles = new Map()
const profileOf = pk => profiles.get(pk) ?? null

test("names fold case and accents; exact > starts with > a word starts with > contains > about only", () => {
  assert.equal(foldText("  Zoë ÅSE "), "zoe ase")
  assert.equal(nameMatch("zoe", { name: "Zoë" }), 0)
  assert.equal(nameMatch("jack", { display_name: "Jack", name: "jd" }), 0)
  assert.equal(nameMatch("jack@example.com", { nip05: "Jack@Example.com" }), 0)
  assert.equal(nameMatch("jack", { nip05: "jack@example.com" }), 0, "the NIP-05's name part is a name")
  assert.equal(nameMatch("jac", { name: "Jackson" }), 1)
  assert.equal(nameMatch("son", { name: "Mary Sonder" }), 2)
  assert.equal(nameMatch("ckso", { name: "Jackson" }), 3)
  assert.equal(nameMatch("bread", { name: "Sam", about: "bread" }), 4)
  assert.equal(nameMatch("@jack", { name: "jack" }), 0, "a leading @ is the mention sign")
})

test("closeness: thread, you (and your other accounts), follows, web, 3+ steps away, outside; 3+ counts as inside", () => {
  const hop = new Map([[D, 3], [Y, 2]])
  const c = { me: ME, own: new Set([ALT]), follows: new Set([F]), web: new Set([W]), hopOf: pk => hop.get(pk) ?? null, thread: new Set([T]) }
  assert.deepEqual([T, ME, ALT, F, W, Y, D, X].map(pk => tierOf(pk, c)), [TIER.thread, 0, 0, 1, 2, 2, 3, 4])
  assert.ok(isInside(D, c), "Logen 5d1ce4cb: 3+ steps away is inside your web")
  assert.ok(!isInside(X, c))
})

test("rank: closeness beats an exact name; inside a tier exact > prefix > contains, then trust score, then shorter", () => {
  profiles.set(F, { name: "Bob Follow" })     // a word starts with "bob"
  profiles.set(X, { name: "bob" })            // exact, but outside
  profiles.set(W, { name: "bobby" })          // prefix, in your web
  profiles.set(Y, { name: "bob" })            // exact, in your web
  profiles.set(D, { name: "jimbob" })         // contains, in your web
  const c = { me: ME, follows: new Set([F]), web: new Set([W, Y, D]), profileOf }
  assert.deepEqual(rankPeople([X, D, W, Y, F], "Bob", c), [F, Y, W, D, X])
  // Trust score breaks a tie in the name match, high first.
  profiles.set(W, { name: "bobbo" }); profiles.set(D, { name: "bobba" })
  const scores = new Map([[W, 10], [D, 90]])
  assert.deepEqual(rankPeople([W, D], "bob", { ...c, scoreOf: pk => scores.get(pk) }), [D, W])
  // With no scores: the shorter name, then the pubkey (stable while results stream in).
  profiles.set(W, { name: "bobbyy" }); profiles.set(D, { name: "bobby" })
  assert.deepEqual(rankPeople([W, D], "bob", c), [D, W])
  profiles.set(W, { name: "bobby" })
  assert.deepEqual(rankPeople([W, D], "bob", c), [D, W].sort())
  assert.deepEqual(rankPeople([D, W], "bob", c), rankPeople([W, D], "bob", c), "arrival order never matters")
})

test("rank: blocked never shows, each person once; names mode drops a non-match, any mode keeps it last", () => {
  profiles.set(F, { name: "carol" }); profiles.set(X, { name: "zed", about: "carol's friend" })
  const c = { me: ME, follows: new Set([F]), profileOf }
  assert.deepEqual(rankPeople([F, F, X], "carol", { ...c, blocked: new Set([F]) }), [])
  assert.deepEqual(rankPeople([X, F], "carol", { ...c, match: "any" }), [F, X])
  assert.deepEqual(rankPeople([X, F], "", c), [F, X], "an empty query keeps everyone, by closeness")
})

test("the rank copy gives hop and score; Search tab: an exact name from outside stays in the fold, 3+ steps is inside", () => {
  const copy = { people: new Map([[D, { score: 40, hop: 3 }]]), globe: new Map() }
  const { hopOf, scoreOf } = fromRankCopy(copy)
  assert.equal(hopOf(D), 3); assert.equal(scoreOf(D), 40); assert.equal(hopOf(X), null)
  assert.deepEqual(fromRankCopy(null), {})
  profiles.set(X, { name: "dana" }); profiles.set(D, { name: "dana smith" }); profiles.set(F, { name: "old dana" })
  const r = shapeResults({ people: [X, D, F], notes: [] }, "dana", { me: ME, follows: [F], wot: new Set(), profileOf, rankCopy: copy })
  assert.deepEqual(r.people, [F, D], "follow first; the 3+ step person is inside")
  assert.deepEqual(r.outsidePeople, [X], "exact name, but outside your web: stays in the fold (Logen 5d1ce4cb)")
})

test("every people box calls the shared ranker; Find someone drops blocked relay hits; pickers ask for people only", async () => {
  const { readFileSync } = await import("node:fs")
  const src = p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")
  const wot = src("screens/WotTopBar.jsx")
  assert.match(wot, /rankPeople\(\[\.\.\.local, \.\.\.found\], text, \{ \.\.\.c, match: "any" \}\)/)
  assert.match(wot, /blocked, profileOf: getProfile/)
  assert.match(src("screens/WotScreen.jsx"), /<WotSearch web=\{web\} me=\{me\} blocked=\{blocked\}/)
  assert.match(src("net/vault-search.js"), /rankPeople\(\[\.\.\.newest\.keys\(\)\]/)
  assert.match(src("net/search.js"), /rankPeople\(people\.filter\(allows\), query, c\)/)
  assert.match(src("components/MentionPicker.jsx"), /searchPeople\(query, \{ limit: 10 \}\)/)
  assert.match(src("napplet/shell-deps.js"), /search: t => searchPeople\(t, \{ limit: 10 \}\)/)
  for (const f of ["components/MentionPicker.jsx", "napplet/shell-deps.js", "net/search.js"]) assert.doesNotMatch(src(f), /searchNostr/, f)
})
