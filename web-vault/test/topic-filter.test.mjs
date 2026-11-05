// The web's port of the iPhone's TopicFeedFilter (net/topic-filter.js), the same cases as TopicFeedFilterTests.swift,
// and the hashtag page a new account opens screened under the Everyone lock (net/feeds.js; RESEARCH/
// NV_NEW_USER_HASHTAG_LOOP_2026_11_05.md). Fake relays; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { screenTopic, isAppMade, linkDomains, followCounts, SCREENED_LINE } from "../src/net/topic-filter.js"
import { fetchStrangerFeed } from "../src/net/feeds.js"
import { everyoneLocked } from "../src/net/global-trust.js"

const post = (id, pubkey, content, hashtags = 1) => ({ id, pubkey, content, tags: Array.from({ length: hashtags }, (_, i) => ["t", `tag${i}`]) })
const ids = ps => ps.map(p => p.id)

test("authors must follow twenty; unknown waits; bots that follow exactly 10 stay out", () => {
  const posts = [post("a", "person", "street photo"), post("b", "bot", "price tick"), post("c", "unknown", "hi there")]
  assert.deepEqual(ids(screenTopic(posts, { person: 120, bot: 0 })), ["a"])
  assert.deepEqual(ids(screenTopic(posts, { person: 20, bot: 19 })), ["a"])
  assert.deepEqual(ids(screenTopic(posts, new Map([["person", 10], ["bot", 10]]))), [])
})

test("hashtag stuffing, link farms (not images), copies once, two per person, adult tags", () => {
  assert.deepEqual(ids(screenTopic([post("a", "p", "five tags", 5), post("b", "q", "six tags", 6)], { p: 50, q: 50 })), ["a"])
  const farm = [0, 1, 2, 3].map(i => post(`f${i}`, `farm${i}`, `thank you donors https://api.gifts.example/m/${i}`))
  const cams = [0, 1, 2, 3].map(i => post(`i${i}`, `cam${i}`, `sunset number ${i} https://blossom.example/${i}.jpg`))
  const all = [...farm, ...cams]
  assert.deepEqual(ids(screenTopic(all, Object.fromEntries(all.map(p => [p.pubkey, 50])))), ["i0", "i1", "i2", "i3"])
  assert.deepEqual(ids(screenTopic([post("a", "p", "GM nostr https://x.example/1"), post("b", "q", "gm   NOSTR https://x.example/2")], { p: 50, q: 50 })), ["a"])
  assert.deepEqual(ids(screenTopic([0, 1, 2, 3, 4].map(i => post(`${i}`, "busy", `post number ${i}`)), { busy: 300 })), ["0", "1"])
  const adult = [
    { id: "a", pubkey: "p", content: "say hi", tags: [["t", "NSFW"]] },
    { id: "b", pubkey: "q", content: "beach", tags: [["content-warning", ""]] },
    { id: "c", pubkey: "r", content: "sunset", tags: [["t", "photography"]] },
  ]
  assert.deepEqual(ids(screenTopic(adult, { p: 50, q: 50, r: 50 })), ["c"])
})

test("posts an app or game made for its player are hidden; a person sharing a link from their own app isn't", () => {
  const game = { id: "g", pubkey: "p", content: "I just obliterated 197 zombies https://plebsvszombies.cc/x", tags: [["client", "Plebs vs. Zombies"]] }
  const person = { id: "h", pubkey: "q", content: "my essay https://trbouma.substack.com/p/x", tags: [["client", "Amethyst"]] }
  const photo = { id: "i", pubkey: "r", content: "walk https://i.nostr.build/a.jpg", tags: [["client", "nostr.build"]] }
  const damus = { id: "d", pubkey: "s", content: "look https://damus.io/note1abc", tags: [["client", "Damus"]] }
  assert.equal(isAppMade(game), true)
  assert.equal(isAppMade(person), false)
  assert.equal(isAppMade(photo), false, "image links are not sites")
  assert.equal(isAppMade(damus), false)
  assert.deepEqual(ids(screenTopic([game, person, photo], { p: 50, q: 50, r: 50 })), ["h", "i"])
  assert.deepEqual([...linkDomains("see https://Example.com/a and https://i.nostr.build/x.PNG")], ["example.com"])
})

test("follow counts come from each author's newest contact list", async () => {
  const pk = c => c.repeat(64)
  const query = async (r, f) => [
    { kind: 3, pubkey: "a", created_at: 1, tags: [["p", pk("1")]] },
    { kind: 3, pubkey: "a", created_at: 2, tags: [["p", pk("1")], ["p", pk("2")], ["p", pk("2")], ["p", "junk"]] },
  ].filter(e => f.authors.includes(e.pubkey))
  assert.deepEqual([...await followCounts(["a", "b"], [], query)], [["a", 2]])
})

test("the loop: under the Everyone lock a hashtag asks the open tag and shows a screened page, your follows on top", async () => {
  const pk = c => c.repeat(64)
  const me = pk("0"), friend = pk("f"), real = pk("a"), bot = pk("b"), web = pk("w")
  const follows = [friend, pk("1")] // 2 follows: still locked
  assert.equal(everyoneLocked(follows, me), true)
  const notes = [
    { id: "1", kind: 1, pubkey: bot, created_at: 900, content: "buy now", tags: [["t", "bitcoin"]] },
    { id: "2", kind: 1, pubkey: real, created_at: 800, content: "my node is synced", tags: [["t", "bitcoin"]] },
    { id: "3", kind: 1, pubkey: friend, created_at: 700, content: "hello from a friend", tags: [["t", "bitcoin"]] },
    { id: "4", kind: 1, pubkey: web, created_at: 600, content: "from my web", tags: [["t", "bitcoin"]] },
  ]
  const asked = []
  const query = async (r, f) => {
    asked.push(f)
    if (f.kinds?.includes(3)) return [{ kind: 3, pubkey: real, created_at: 1, tags: Array.from({ length: 25 }, (_, i) => ["p", String(i).padStart(64, "0")]) },
      { kind: 3, pubkey: friend, created_at: 1, tags: [["p", pk("9")]] }]
    return notes
  }
  const page = await fetchStrangerFeed({ mode: "hashtag", tag: "bitcoin" }, ["wss://r.example"], { trust: new Set([web]), screened: true, follows, query })
  assert.deepEqual(page.map(n => n.id), ["3", "4", "2"], "your follow and your web first (a friend who follows 1 person too), then the screened rest; the bot is out")
  assert.ok(!asked[0].authors && asked[0]["#t"][0] === "bitcoin", "the open tag, not only trusted authors")
  // Not screened (5 follows or more): as before, nothing without a web.
  assert.deepEqual(await fetchStrangerFeed({ mode: "hashtag", tag: "bitcoin" }, ["wss://r.example"], { trust: null, query }), [])
  assert.equal(SCREENED_LINE, "Unfiltered: people you don't know yet")
})
