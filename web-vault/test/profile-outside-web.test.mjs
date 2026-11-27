// The profile page counts and draws only people inside your web (Logen 2026-11-27,
// RESEARCH/NV_WEB_PROFILE_OUTSIDE_WEB_AUDIT.md fixes 1-6): Following and Followers in your web, and a repost, quote,
// "reply to" or bio mention of someone outside it is a short line with nothing fetched for them.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fetchFollowersInWeb, keptFollowers, webKey, webKeysOf, WEB_CHUNK, WEB_FILTERS } from "../src/net/followers.js"
import { profileOutside, OUTSIDE_TEXT } from "../src/components/outside-web.js"

const read = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const key = i => i.toString(16).padStart(64, "0")
const P = "f".repeat(64)

test("Followers in your web: the web goes out as the authors, 250 a filter and 4 filters an ask, and the asks add up", async () => {
  const web = Array.from({ length: 2600 }, (_, i) => key(i + 1))
  const asks = []
  const answers = { "wss://a": [100, 50, 7], "wss://b": [90, 60, null] }
  const count = async (url, filters) => {
    asks.push({ url, filters })
    const i = Math.floor(web.indexOf(filters[0].authors[0]) / (WEB_CHUNK * WEB_FILTERS))
    return answers[url][i]
  }
  const drawn = []
  const n = await fetchFollowersInWeb(P, [...web, P, web[0]], c => drawn.push(c), { relays: Object.keys(answers), count })
  // Per ask the larger relay answer (100, 60, 7); the asks' authors don't overlap, so they are added.
  assert.equal(n, 167)
  assert.equal(drawn.at(-1), 167)
  assert.equal(asks.length, 6, "3 asks to each of the 2 relays")
  const first = asks.find(a => a.url === "wss://a").filters
  assert.equal(first.length, WEB_FILTERS)
  assert.deepEqual(first[0].kinds, [3])
  assert.deepEqual(first[0]["#p"], [P])
  assert.equal(first[0].authors.length, WEB_CHUNK)
  const authors = asks.filter(a => a.url === "wss://a").flatMap(a => a.filters.flatMap(f => f.authors))
  assert.equal(authors.length, 2600, "each web key once, the profile itself left out")
  assert.ok(!authors.includes(P))
  assert.equal(keptFollowers(P, Date.now(), webKey([...web, P, web[0]])), 167, "kept for this web")
  assert.equal(keptFollowers(P), undefined, "not as the old all-relays count")
})

test("Followers in your web: no relay counts is null (the header keeps its dash); an empty web is 0", async () => {
  assert.equal(await fetchFollowersInWeb(P, [key(1)], () => {}, { relays: ["wss://a"], count: async () => null }), null)
  assert.equal(await fetchFollowersInWeb(P, [], () => {}, { relays: ["wss://a"], count: async () => 5 }), 0)
})

test("the web the counts read: the gate's web and your own keys, nobody blocked", () => {
  const gate = { web: new Set([key(1), key(2)]), own: new Set([key(3)]), blocked: new Set([key(2)]) }
  assert.deepEqual(webKeysOf(gate).sort(), [key(1), key(3)])
  assert.deepEqual(webKeysOf(null), [])
})

test("the profile's gate: its owner always in, everyone else by your web", () => {
  const inside = (pk, also = []) => also.includes(pk) || pk === key(1)
  const outside = profileOutside(inside, P)
  assert.equal(outside(P), false)
  assert.equal(outside(key(1)), false)
  assert.equal(outside(key(2)), true)
  assert.equal(outside(""), false)
})

test("both profile pages count Following and Followers in your web and gate what they bring in", () => {
  for (const f of ["screens/ProfileScreen.jsx", "screens/PersonScreen.jsx"]) {
    const s = read(f)
    assert.match(s, /<OutsideWeb\.Provider value=\{outside\}>/, f)
    assert.match(s, /follows=\{[^}]*\.filter\(pk => web\.inside\(pk\)\)\.length/, `${f}: Following in your web`)
    assert.match(s, /webKeys=\{webKeys\}/, f)
  }
  const header = read("components/ProfileHeader.jsx")
  assert.match(header, /fetchFollowersInWeb\(pk, webKeys/)
  assert.doesNotMatch(header, /fetchFollowers\(pk/, "the raw count of every kind 3 is gone from the header")
})

test("a repost, quote, reply-to and mention of someone outside your web: a short line, nothing of theirs fetched", () => {
  const card = read("components/NoteCard.jsx"), quote = read("components/QuotedNote.jsx"), text = read("components/NoteText.jsx")
  assert.match(card, /if \(inner\?\.pubkey && outside\?\.\(inner\.pubkey\)\) return outsideRepost\(event, footer\)/, "fix 1: a kind 6")
  assert.match(card, /if \(inner && outside\?\.\(inner\.pubkey\)\) return outsideRepost\(event, footer\)/, "fix 1: a kind 16")
  assert.match(card, /if \(outside\?\.\(ev\.pubkey\)\) return <div class="note-text muted">\{OUTSIDE_TEXT\.repost\}/, "fix 1: a repost fetched by id")
  assert.match(card, /reply to \{outside\?\.\(replyTo\) \? OUTSIDE_TEXT\.reply : <Mention/, "fix 3")
  assert.match(quote, /const skip = !!\(q\?\.author && outside\?\.\(q\.author\)\)\n  const ev = useQuote\(q, memoryOnly, skip\)/, "fix 2: an nevent naming its author isn't fetched")
  assert.match(quote, /if \(skip\) return\n/)
  assert.match(quote, /if \(outside\?\.\(ev\.pubkey\)\) return <div class="quote quote-missing">\{OUTSIDE_TEXT\.quote\}/, "fix 2")
  assert.match(quote, /if \(ev && src && !outside\?\.\(ev\.pubkey\)\) wantProfile/, "fix 2: no kind 0 for them")
  assert.match(text, /if \(outside\?\.\(pubkey\)\) return <a class="mention mention-outside"/, "fix 6 (and every @name on the page)")
  assert.equal(OUTSIDE_TEXT.reply, "someone outside your web")
})

test("the desktop napplet's own-profile card counts Following and Followers inside your web too", () => {
  const pane = read("napplet/ReaderPane.jsx")
  assert.match(pane, /fetchFollowersInWeb\(me, keys, mineChanged\)/)
  assert.match(pane, /const follows = liveCtx\.account\.follows\.filter\(pk => w\.inside\(pk\)\)\.length/)
  assert.match(pane, /useEffect\(\(\) => \{ live\.current\?\.mineChanged\?\.\(\) \}, \[web\.gate\]\)/, "asks again as the web grows")
  assert.doesNotMatch(pane, /fetchFollowers\(me/, "no raw count of every kind 3")
})
