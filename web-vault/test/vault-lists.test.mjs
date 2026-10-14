// Vault tab lists: the "Vault" activity lines folded as the phone folds them (VaultActivity.lines), the Notes /
// Articles / Highlights filters, pictures for Media, Likes and Zaps received or given, and followers from kind 3
// lists. Throwaway keys and fake Haven routes: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import {
  MODES, FILTERS, defaultFilter, isMode, imagesOf, previewOf, activityRows, activityFilter, notesFor, articlesFor, isRecipe,
  highlightsFor, highlightSource, mediaFor, likesFor, zapsFor, zapSender, followersOf, followersFilter, followersSeenAt, markFollowersSeen,
  readOwn, readInbound, fetchOwnExtras, INBOUND_KINDS,
} from "../src/net/vault-lists.js"

const ME = "a".repeat(64), ALICE = "b".repeat(64), BOB = "c".repeat(64), CAROL = "d".repeat(64)
const N1 = "1".repeat(64), N2 = "2".repeat(64)
let seq = 0
const ev = (kind, pubkey, tags = [], content = "", created_at = 1000 + ++seq) => ({ id: `${kind}-${pubkey.slice(0, 1)}-${seq}`.padEnd(64, "0"), kind, pubkey, tags, content, created_at })
const zapReq = (sender, tags = [], content = "") => JSON.stringify({ kind: 9734, pubkey: sender, tags, content })
const mine = [{ ...ev(1, ME, [], "my first note https://x.io/a.jpg"), id: N1 }, { ...ev(1, ME, [], "my second"), id: N2 }]

test("modes and filters are the phone's, in its order, each with a default", () => {
  assert.deepEqual(MODES.map(m => m.id), ["activity", "notes", "articles", "highlights", "media", "likes", "zaps", "followers"])
  assert.equal(MODES[0].title, "Vault")
  for (const m of MODES) assert.equal(typeof defaultFilter(m.id), "string")
  assert.equal(defaultFilter("media"), "")
  assert.equal(FILTERS.likes.map(f => f.title).join(", "), "Likes received, Likes given")
  assert.ok(isMode("notes") && !isMode("dashboard") && !isMode(undefined))
})

test("pictures come from imeta tags first, then bare links; the preview leaves them out", () => {
  const n = ev(1, ME, [["imeta", "url https://img.io/one.png", "m image/png"]], "look  https://img.io/two.jpg\nand https://img.io/one.png text")
  assert.deepEqual(imagesOf(n), ["https://img.io/one.png", "https://img.io/two.jpg"])
  assert.equal(previewOf(n), "look and text")
  const a = ev(30023, ME, [["title", "A title"], ["summary", "S"]], "body")
  assert.equal(previewOf(a), "A title")
  assert.equal(previewOf(ev(30023, ME, [["summary", "Only summary"]], "body")), "Only summary")
})

test("likes, reposts and plain zaps on one of your notes fold into one line each; a zap with words stands alone", () => {
  const inbound = [
    ev(7, ALICE, [["e", N1], ["p", ME]], "+"),
    ev(7, BOB, [["e", N1], ["p", ME]], "🔥"),
    ev(6, CAROL, [["e", N1], ["p", ME]]),
    ev(9735, "f".repeat(64), [["p", ME], ["e", N1], ["description", zapReq(ALICE, [["e", N1]])], ["bolt11", "lnbc210n1"]]),
    ev(9735, "f".repeat(64), [["p", ME], ["e", N1], ["description", zapReq(BOB, [["e", N1]])], ["bolt11", "lnbc210n1"]]),
    ev(9735, "f".repeat(64), [["p", ME], ["e", N2], ["description", zapReq(CAROL, [["e", N2]], "great post")], ["bolt11", "lnbc1u1"]]),
  ]
  const rows = activityRows(inbound, ME, { mine })
  const like = rows.find(r => r.kind === "like")
  assert.equal(like.actors.length, 2)
  assert.deepEqual(like.emojis, ["❤️", "🔥"])
  assert.equal(like.openId, N1)
  assert.equal(like.preview, "my first note")
  assert.deepEqual(like.images, ["https://x.io/a.jpg"])
  const repost = rows.find(r => r.kind === "repost")
  assert.deepEqual(repost.actors, [CAROL])
  const zaps = rows.filter(r => r.kind === "zap")
  assert.equal(zaps.length, 2)
  const folded = zaps.find(z => z.openId === N1)
  assert.equal(folded.sats, 42)
  assert.equal(folded.actors.length, 2)
  const worded = zaps.find(z => z.openId === N2)
  assert.deepEqual(worded.actors, [CAROL])
  assert.equal(worded.preview, "great post")
  assert.equal(worded.sats, 100)
  // Newest first; the line's time is its newest event's.
  assert.ok(rows.every((r, i) => !i || rows[i - 1].created_at >= r.created_at))
})

test("replies, mentions and quotes are their own lines; what doesn't tag you or isn't about your note is left out", () => {
  const inbound = [
    ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "a reply"),
    ev(1, BOB, [["p", ME]], "a mention"),
    ev(1, CAROL, [["q", N1], ["p", ME]], "quoting you"),
    ev(1, CAROL, [["p", ALICE]], "not for you"),
    ev(7, ALICE, [["e", "9".repeat(64)], ["p", ME]], "+"), // a like on a note that isn't yours
    ev(6, BOB, [["p", ME]]), // a repost with no target
    ev(1, ME, [["p", ME]], "me tagging me"),
  ]
  const rows = activityRows(inbound, ME, { mine })
  assert.deepEqual(rows.map(r => r.kind).sort(), ["mention", "quote", "reply"])
  assert.equal(rows.find(r => r.kind === "quote").preview, "quoting you")
  assert.deepEqual(rows.filter(r => activityFilter(r, "mentions")).length, 3)
  assert.ok(rows.every(r => activityFilter(r, "all")))
})

test("articles and highlights tagging you are lines; follows on one day fold into one line", () => {
  const inbound = [ev(30023, ALICE, [["p", ME], ["title", "On you"]], "…"), ev(9802, BOB, [["p", ME]], "a quote")]
  const day = Math.floor(Date.UTC(2026, 9, 14, 12) / 1000)
  const follows = [{ pubkey: ALICE, at: day }, { pubkey: BOB, at: day + 60 }, { pubkey: CAROL, at: day + 3 * 86400 }, { pubkey: ME, at: day }]
  const rows = activityRows(inbound, ME, { mine, follows })
  assert.deepEqual(rows.map(r => r.kind).sort(), ["article", "follow", "follow", "highlight"])
  const sameDay = rows.find(r => r.kind === "follow" && r.actors.length === 2)
  assert.deepEqual(sameDay.actors, [BOB, ALICE]) // newest first within the line
  assert.equal(sameDay.created_at, day + 60)
  assert.equal(rows.find(r => r.kind === "article").preview, "On you")
})

test("blocked people are left out of every line; a like from only blocked people disappears", () => {
  const inbound = [ev(7, ALICE, [["e", N1], ["p", ME]], "+"), ev(1, ALICE, [["p", ME]], "hi"), ev(1, BOB, [["p", ME]], "hello")]
  const rows = activityRows(inbound, ME, { mine, blocked: new Set([ALICE]) })
  assert.deepEqual(rows.map(r => r.kind), ["mention"])
  assert.deepEqual(rows[0].actors, [BOB])
})

test("notes: all is yours plus the ones tagging you, mine is yours, tagged is theirs; a seen id isn't repeated", () => {
  const own = [...mine, ev(6, ME, [["e", N1]]), ev(30023, ME, [["title", "x"]])]
  const inbound = [ev(1, ALICE, [["p", ME]], "tagging you"), ev(1, BOB, [["p", CAROL]], "not you"), mine[0]]
  assert.equal(notesFor(own, inbound, ME, "all").length, 4)
  assert.equal(notesFor(own, inbound, ME, "mine").length, 3)
  assert.deepEqual(notesFor(own, inbound, ME, "tagged").map(n => n.pubkey), [ALICE])
  assert.equal(notesFor(own, inbound, ME, "tagged", new Set([ALICE])).length, 0)
})

test("articles: recipes are the ones tagged zapcooking or nostrcooking", () => {
  const own = [ev(30023, ME, [["title", "Soup"], ["t", "zapcooking"]]), ev(30023, ME, [["title", "Essay"]]), ev(1, ME, [], "note")]
  const inbound = [ev(30023, ALICE, [["p", ME], ["t", "NostrCooking"]])]
  assert.equal(articlesFor(own, inbound, ME, "all").length, 3)
  assert.deepEqual(articlesFor(own, inbound, ME, "recipes").map(a => a.pubkey), [ALICE, ME])
  assert.ok(isRecipe(own[0]) && !isRecipe(own[1]))
})

test("highlights: yours and the ones tagging you, with the source they came from", () => {
  const own = [ev(9802, ME, [["r", "https://a.io/post"]], "quoted")]
  const inbound = [ev(9802, ALICE, [["p", ME], ["a", "30023:x:y"]], "yours quoted")]
  assert.equal(highlightsFor(own, inbound, ME, "all").length, 2)
  assert.equal(highlightsFor(own, inbound, ME, "mine").length, 1)
  assert.equal(highlightSource(own[0]), "https://a.io/post")
  assert.equal(highlightSource(inbound[0]), "30023:x:y")
  assert.equal(highlightSource(ev(9802, ME, [], "")), "")
})

test("media: every picture in your notes and articles once, newest first, with the note it is in", () => {
  const own = [
    ev(1, ME, [], "https://x.io/old.jpg", 10),
    ev(1, ME, [["imeta", "url https://x.io/new.png"]], "https://x.io/new.png", 30),
    ev(30023, ME, [], "https://x.io/old.jpg https://x.io/art.webp", 20),
    ev(7, ME, [], "https://x.io/not-a-note.jpg", 40),
  ]
  const m = mediaFor(own)
  assert.deepEqual(m.map(p => p.url), ["https://x.io/new.png", "https://x.io/old.jpg", "https://x.io/art.webp"])
  assert.equal(m[1].noteId, own[2].id)
})

test("likes: received folds others' reactions per note; given lists your own reactions", () => {
  const own = [ev(7, ME, [["e", N1], ["p", ALICE]], "+"), ev(1, ME, [], "x")]
  const inbound = [ev(7, ALICE, [["e", N1], ["p", ME]], "+"), ev(7, BOB, [["e", N1], ["p", ME]], "🤙"), ev(7, CAROL, [["e", N2], ["p", ME]], "+"), ev(1, ALICE, [["p", ME]], "no")]
  const received = likesFor(own, inbound, ME, "received")
  assert.equal(received.length, 2)
  assert.equal(received.find(r => r.noteId === N1).who.length, 2)
  const given = likesFor(own, inbound, ME, "given")
  assert.equal(given.length, 1)
  assert.deepEqual(given[0].who, [ME])
  assert.equal(given[0].noteId, N1)
  assert.equal(likesFor(own, inbound, ME, "received", new Set([CAROL])).length, 1)
})

test("zaps: received are receipts on your notes; given are receipts whose request you signed", () => {
  const LN = "f".repeat(64)
  const inbound = [ev(9735, LN, [["p", ME], ["e", N1], ["description", zapReq(ALICE, [["e", N1]])], ["bolt11", "lnbc210n1"]])]
  const given = [
    ev(9735, LN, [["p", ALICE], ["P", ME], ["e", N2], ["description", zapReq(ME, [["e", N2]])], ["bolt11", "lnbc1u1"]]),
    ev(9735, LN, [["p", ALICE], ["P", ME], ["description", zapReq(BOB, [])]]), // a forged P: the request says Bob
  ]
  const r = zapsFor(given, inbound, ME, "received")
  assert.equal(r.length, 1)
  assert.equal(r[0].sats, 21)
  const g = zapsFor(given, inbound, ME, "given")
  assert.equal(g.length, 1)
  assert.equal(g[0].to, ALICE)
  assert.equal(g[0].noteId, N2)
  assert.equal(g[0].sats, 100)
  assert.equal(zapSender(given[1]), BOB)
})

test("followers: each author's newest list counts, only while it still names you; newest first", () => {
  const lists = [
    ev(3, ALICE, [["p", ME]], "", 100),
    ev(3, ALICE, [["p", BOB]], "", 200), // unfollowed
    ev(3, BOB, [["p", ME]], "", 150),
    ev(3, BOB, [["p", ME], ["p", CAROL]], "", 50), // older
    ev(3, CAROL, [["p", ME]], "", 300),
    ev(3, ME, [["p", ME]], "", 400),
    ev(1, CAROL, [["p", ME]], "", 500),
  ]
  const f = followersOf(lists, ME)
  assert.deepEqual(f, [{ pubkey: CAROL, at: 300 }, { pubkey: BOB, at: 150 }])
  assert.deepEqual(followersOf(lists, ME, new Set([CAROL])).map(x => x.pubkey), [BOB])
  assert.deepEqual(followersFilter(f, "new", 200).map(x => x.pubkey), [CAROL])
  assert.deepEqual(followersFilter(f, "new", undefined).length, 2)
  assert.equal(followersFilter(f, "all", 999).length, 2)
})

test("the followers seen mark is per account in storage", () => {
  const store = new Map()
  const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  assert.equal(followersSeenAt(ME, storage), 0)
  markFollowersSeen(ME, 1234, storage)
  assert.equal(followersSeenAt(ME, storage), 1234)
  assert.equal(followersSeenAt(ALICE, storage), 0)
})

test("reading: own from the outbox, inbound from the inbox when there is one, and fetched events kept in it", async () => {
  const asked = []
  const kept = []
  const vault = {
    outbox: { query: async f => { asked.push(["outbox", f]); return [mine[0], mine[0], mine[1]].filter(e => !f.ids || f.ids.includes(e.id)) } },
    inbox: { query: async f => { asked.push(["inbox", f]); return [ev(7, ALICE, [["e", N1], ["p", ME]], "+")] }, event: async e => { kept.push(e.id); return { ok: true } } },
    feed: { query: async () => [] },
  }
  assert.equal((await readOwn(vault, ME)).length, 2) // the duplicate dropped
  assert.deepEqual(asked[0][1].authors, [ME])
  assert.equal((await readInbound(vault, ME)).length, 1)
  assert.deepEqual(asked[1][1], { kinds: INBOUND_KINDS, "#p": [ME], limit: 500 })
  assert.deepEqual(await readInbound({ outbox: vault.outbox }, ME), [])
})

test("every filter has a title; the long ones a short pill form", () => {
  for (const list of Object.values(FILTERS)) for (const f of list) {
    assert.ok(f.title.length > 0)
    if (f.pill !== undefined) assert.ok(f.pill.length < f.title.length)
  }
  assert.equal(typeof fetchOwnExtras, "function")
})
