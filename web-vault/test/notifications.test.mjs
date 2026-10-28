// Notifications: classifying `#p` events into rows (who / what / which note), folding several people on one note
// into one row, and the sats paid by a zap from its bolt11 (or the zap request's amount tag).
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { groupNotifications, classify, replyTarget, reactionEmoji, zapSats, bolt11Sats, formatSats, zapRequest } from "../src/net/notifications.js"

// Throwaway keys: a zap request only names its sender when that sender really signed it.
const keys = new Map()
const person = () => { const sk = generateSecretKey(), pk = getPublicKey(sk); keys.set(pk, sk); return pk }
const ME = person(), ALICE = person(), BOB = person(), CAROL = "d".repeat(64)
const N1 = "1".repeat(64), N2 = "2".repeat(64), N3 = "3".repeat(64)
let seq = 0
const ev = (kind, pubkey, tags, content = "", created_at = 1000 + seq) => ({ id: `${kind}-${pubkey.slice(0, 2)}-${++seq}`.padEnd(64, "0"), kind, pubkey, tags, content, created_at })
const zapReq = (sender, tags = [], extra = {}) =>
  JSON.stringify(finalizeEvent({ kind: 9734, created_at: 1000, tags: [["p", ME], ...tags], content: "", ...extra }, keys.get(sender)))

test("a reply to the user's note is a reply row pointing at that note", () => {
  const r = classify(ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "nice"), ME)
  assert.equal(r.type, "reply")
  assert.equal(r.who, ALICE)
  assert.equal(r.noteId, N1)
})

test("a kind 1 with no e tag is a mention", () => {
  const r = classify(ev(1, ALICE, [["p", ME]], "hey nostr:npub…"), ME)
  assert.equal(r.type, "mention")
  assert.equal(r.noteId, null)
})

test("reply target: reply marker beats root, root beats positional, positional takes the last e", () => {
  assert.equal(replyTarget([["e", N1, "", "root"], ["e", N2, "", "reply"]]), N2)
  assert.equal(replyTarget([["e", N2, "", "reply"], ["e", N1, "", "root"]]), N2)
  assert.equal(replyTarget([["e", N1, "", "root"]]), N1)
  assert.equal(replyTarget([["e", N1], ["e", N2]]), N2)
  assert.equal(replyTarget([["e", "not-hex"], ["p", ME]]), null)
})

test("events that don't tag the user, or that the user sent, are not notifications", () => {
  assert.equal(classify(ev(1, ALICE, [["p", BOB]]), ME), null)
  assert.equal(classify(ev(7, ME, [["e", N1], ["p", ME]], "+"), ME), null)
  assert.equal(classify(ev(4, ALICE, [["p", ME]]), ME), null)
  assert.equal(classify({ kind: 1, pubkey: ALICE }, ME), null)
})

test("a repost and a reaction point at the last e tag", () => {
  const rp = classify(ev(6, ALICE, [["e", N1], ["p", ME]]), ME)
  assert.equal(rp.type, "repost")
  assert.equal(rp.noteId, N1)
  const rx = classify(ev(7, BOB, [["e", N2], ["e", N1], ["p", ME]], "🤙"), ME)
  assert.equal(rx.type, "reaction")
  assert.equal(rx.noteId, N1)
  assert.equal(rx.emoji, "🤙")
})

test("reaction content: + and empty are a heart, - is a thumbs down, long custom content is cut", () => {
  assert.equal(reactionEmoji("+"), "❤️")
  assert.equal(reactionEmoji(""), "❤️")
  assert.equal(reactionEmoji("-"), "👎")
  assert.equal(reactionEmoji("🔥"), "🔥")
  assert.equal(reactionEmoji(":a_long_shortcode:"), ":a_long_")
})

test("a zap's who is the zap request's sender, not the LNURL server that signed the 9735", () => {
  const LNURL = "e".repeat(64)
  const z = classify(ev(9735, LNURL, [["p", ME], ["e", N1], ["bolt11", "lnbc210n1pjfakefakefakefakefakefakefakefakefakefakefakefakefake"], ["description", zapReq(ALICE, [["e", N1]])]]), ME)
  assert.equal(z.type, "zap")
  assert.equal(z.who, ALICE)
  assert.equal(z.noteId, N1)
  assert.equal(z.sats, 21)
})

test("a receipt names nobody, and is no notification, unless its zap request holds up", () => {
  const LNURL = "e".repeat(64)
  const zap = (tags, desc) => ev(9735, LNURL, [["p", ME], ["e", N1], ["bolt11", "lnbc210n1x"], ...tags, ["description", desc]])
  const ok = zap([["P", ALICE]], zapReq(ALICE, [["amount", "21000"]]))
  assert.equal(classify(ok, ME).who, ALICE, "the control: a real one is a notification")
  assert.equal(classify(zap([], "{not json"), ME), null, "broken description")
  assert.equal(classify(ev(9735, LNURL, [["p", ME], ["P", BOB]]), ME), null, "no request: the P tag alone names no one")
  const unsigned = JSON.stringify({ kind: 9734, pubkey: ALICE, tags: [["p", ME]], content: "", created_at: 1000 })
  assert.equal(classify(zap([], unsigned), ME), null, "unsigned request in Alice's name")
  const req = JSON.parse(zapReq(BOB))
  assert.equal(classify(zap([], JSON.stringify({ ...req, pubkey: ALICE })), ME), null, "Bob's signature, Alice's name")
  assert.equal(classify(zap([], JSON.stringify({ ...req, verified: true, pubkey: ALICE })), ME), null, "a verified flag in the JSON is ignored")
  assert.equal(classify(zap([], zapReq(ALICE, [], { tags: [["p", CAROL]] })), ME), null, "Alice's real zap to Carol, replayed at me")
  assert.equal(classify(zap([["P", BOB]], zapReq(ALICE)), ME), null, "receipt's P names someone else")
  assert.equal(classify(zap([], zapReq(ALICE, [["amount", "1200000000"]])), ME), null, "invoice charges 21, request asked 1.2M")
  assert.equal(zapRequest(ok)?.pubkey, ALICE)
})

test("the user zapping themself is not a notification", () => {
  assert.equal(classify(ev(9735, "e".repeat(64), [["p", ME], ["description", zapReq(ME)]]), ME), null)
})

test("bolt11 amounts: multipliers, no amount, not an invoice", () => {
  assert.equal(bolt11Sats("lnbc210n1pjfakefake"), 21)
  assert.equal(bolt11Sats("lnbc21u1pjfakefake"), 2100)
  assert.equal(bolt11Sats("lnbc1m1pjfakefake"), 100_000)
  assert.equal(bolt11Sats("lnbc11pjfakefake"), 100_000_000)
  assert.equal(bolt11Sats("lnbc2500u1pjfakefake"), 250_000)
  assert.equal(bolt11Sats("lnbc1500n1pjfakefake"), 150)
  assert.equal(bolt11Sats("lnbc10p1pjfakefake"), 0, "1 millisat rounds down to 0 sats")
  assert.equal(bolt11Sats("LNBC210N1PJFAKEFAKE"), 21, "case-insensitive")
  assert.equal(bolt11Sats("lntb210n1pjfakefake"), 21, "testnet")
  assert.equal(bolt11Sats("lnbc1pjfakefake"), 0, "no amount")
  assert.equal(bolt11Sats(""), 0)
  assert.equal(bolt11Sats(undefined), 0)
  assert.equal(bolt11Sats("not an invoice"), 0)
})

test("zapSats prefers the bolt11, then the zap request's amount tag in millisats", () => {
  assert.equal(zapSats(ev(9735, BOB, [["bolt11", "lnbc420n1x"], ["description", zapReq(ALICE, [["amount", "999000"]])]])), 42)
  assert.equal(zapSats(ev(9735, BOB, [["p", ME], ["description", zapReq(ALICE, [["amount", "21000"]])]])), 21)
  assert.equal(zapSats(ev(9735, BOB, [["p", ME], ["description", zapReq(ALICE, [["amount", "oops"]])]])), 0)
  assert.equal(zapSats(ev(9735, BOB, [["p", ME], ["description", JSON.stringify({ kind: 9734, pubkey: ALICE, tags: [["p", ME], ["amount", "21000"]] })]])), 0, "unsigned request: no amount")
  assert.equal(zapSats(ev(9735, BOB, [])), 0)
})

test("formatSats: 21, 1.2k, 100k, 1.5M", () => {
  assert.equal(formatSats(21), "21")
  assert.equal(formatSats(1200), "1.2k")
  assert.equal(formatSats(1000), "1k")
  assert.equal(formatSats(100_000), "100k")
  assert.equal(formatSats(1_500_000), "1.5M")
})

test("grouping: newest first, own events out, duplicates out", () => {
  const evs = [
    ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "old", 100),
    ev(1, BOB, [["e", N1, "", "reply"], ["p", ME]], "new", 300),
    ev(1, ME, [["e", N1, "", "reply"], ["p", ME]], "mine", 400),
  ]
  const rows = groupNotifications([...evs, evs[0]], ME)
  assert.deepEqual(rows.map(r => r.events[0].content), ["new", "old"])
  assert.ok(rows.every(r => r.type === "reply" && r.who.length === 1))
})

test("grouping: reactions on the same note fold into one row; replies never fold", () => {
  const rows = groupNotifications([
    ev(7, ALICE, [["e", N1], ["p", ME]], "+", 10),
    ev(7, BOB, [["e", N1], ["p", ME]], "🔥", 30),
    ev(7, CAROL, [["e", N1], ["p", ME]], "+", 20),
    ev(7, ALICE, [["e", N2], ["p", ME]], "+", 25),
    ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "a", 5),
    ev(1, BOB, [["e", N1, "", "reply"], ["p", ME]], "b", 6),
  ], ME)
  assert.deepEqual(rows.map(r => [r.type, r.noteId === N1 ? "N1" : "N2", r.who.length]), [
    ["reaction", "N1", 3], ["reaction", "N2", 1], ["reply", "N1", 1], ["reply", "N1", 1],
  ])
  const folded = rows[0]
  assert.deepEqual(folded.who, [BOB, CAROL, ALICE], "newest reactor leads")
  assert.equal(folded.created_at, 30)
  assert.equal(folded.emoji, "🔥", "the row shows the newest reaction's emoji")
  assert.equal(folded.events.length, 3)
})

test("grouping: zaps on one note add up their sats, and one person twice is counted once in who", () => {
  const LNURL = "e".repeat(64)
  const zap = (sender, sats, t) => ev(9735, LNURL, [["p", ME], ["e", N3], ["bolt11", `lnbc${sats * 10}n1x`], ["description", zapReq(sender, [["e", N3]])]], "", t)
  const rows = groupNotifications([zap(ALICE, 21, 1), zap(ALICE, 21, 2), zap(BOB, 100, 3)], ME)
  assert.equal(rows.length, 1)
  assert.equal(rows[0].sats, 142)
  assert.deepEqual(rows[0].who, [BOB, ALICE])
})

test("grouping: a repost and a reaction on the same note stay separate rows", () => {
  const rows = groupNotifications([ev(6, ALICE, [["e", N1], ["p", ME]]), ev(7, ALICE, [["e", N1], ["p", ME]], "+")], ME)
  assert.deepEqual(rows.map(r => r.type).sort(), ["reaction", "repost"])
})

test("grouping: reactions with no e tag don't fold into each other", () => {
  const rows = groupNotifications([ev(7, ALICE, [["p", ME]], "+"), ev(7, BOB, [["p", ME]], "+")], ME)
  assert.equal(rows.length, 2)
})

// The iPhone's other notification types (Models/VaultActivity.swift): quotes, follows, kind 16 reposts, articles,
// highlights, and zaps whose comment or missing note gives them a row of their own.
test("a kind 1 with a q tag is a quote of that note, even with e tags", () => {
  const r = classify(ev(1, ALICE, [["e", N2, "", "root"], ["q", N1], ["p", ME]], "look at this"), ME)
  assert.equal(r.type, "quote")
  assert.equal(r.noteId, N1)
})

test("a contact list naming the user is a follow; follows on one day share a row, other days don't", () => {
  const day = 86_400 * 20000
  const rows = groupNotifications([
    ev(3, ALICE, [["p", ME], ["p", BOB]], "", day + 10),
    ev(3, BOB, [["p", ME]], "", day + 20),
    ev(3, CAROL, [["p", ME]], "", day - 10),
  ], ME)
  assert.deepEqual(rows.map(r => [r.type, r.who]), [["follow", [BOB, ALICE]], ["follow", [CAROL]]])
})

test("a kind 16 generic repost folds with kind 6 reposts of the same note", () => {
  const rows = groupNotifications([ev(6, ALICE, [["e", N1], ["p", ME]]), ev(16, BOB, [["e", N1], ["p", ME], ["k", "20"]])], ME)
  assert.equal(rows.length, 1)
  assert.equal(rows[0].type, "repost")
  assert.deepEqual(rows[0].who.sort(), [ALICE, BOB].sort())
})

test("an article that tags the user carries its title; a highlight points at its note", () => {
  const a = classify(ev(30023, ALICE, [["d", "x"], ["title", "On vaults"], ["p", ME]], "# long"), ME)
  assert.equal(a.type, "article")
  assert.equal(a.comment, "On vaults")
  const h = classify(ev(9802, BOB, [["e", N2], ["p", ME]], "a quoted line"), ME)
  assert.equal(h.type, "highlight")
  assert.equal(h.noteId, N2)
})

test("a zap's words and note come from the signed request; with words, or on the profile, it keeps its own row", () => {
  const LNURL = "e".repeat(64)
  const zap = (sender, words, tags, t) => ev(9735, LNURL, [["p", ME], ["bolt11", "lnbc210n1x"], ["description", zapReq(sender, tags, { content: words })]], "receipt text", t)
  const rows = groupNotifications([
    zap(ALICE, "", [["e", N3]], 1),
    zap(BOB, "", [["e", N3]], 2),
    zap(BOB, "great post", [["e", N3]], 3),
    zap(ALICE, "", [], 4),
  ], ME)
  assert.deepEqual(rows.map(r => [r.who, r.noteId, r.comment]), [
    [[ALICE], null, ""],
    [[BOB], N3, "great post"],
    [[BOB, ALICE], N3, ""],
  ])
})

// All / Mentions and the unread mark (VaultToolbar, VaultActivityList.activityVisit).
test("the Mentions filter keeps replies, mentions and quotes only", async () => {
  const { filterRows } = await import("../src/net/notifications.js")
  const rows = ["reply", "mention", "quote", "reaction", "repost", "zap", "follow", "article", "highlight"].map((type, i) => ({ id: String(i), type }))
  assert.deepEqual(filterRows(rows, "mentions").map(r => r.type), ["reply", "mention", "quote"])
  assert.equal(filterRows(rows, "all").length, 9)
})

test("unread: a first visit marks nothing new; the next shows what came since; leaving moves the mark too", async () => {
  const { visitNotifications, seenKey } = await import("../src/net/notifications.js")
  const store = new Map()
  const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  assert.equal(visitNotifications(ME, { arriving: true, storage, now: 100 }), 100)
  visitNotifications(ME, { arriving: false, storage, now: 150 })
  assert.equal(visitNotifications(ME, { arriving: true, storage, now: 400 }), 150)
  assert.equal(store.get(seenKey(ME)), "400")
  // Another account keeps its own mark.
  assert.equal(visitNotifications(ALICE, { arriving: true, storage, now: 500 }), 500)
  // A browser that won't store anything still opens the list.
  assert.equal(visitNotifications(ME, { arriving: true, storage: { getItem() { throw new Error("no") }, setItem() { throw new Error("no") } }, now: 9 }), 9)
})

// Paging past the first 100, notes from outside the network, and the emoji a folded like row shows
// (VaultActivityList.loadMoreActivity, ContentFilter.isOutside, reactionEmojiSummary).
test("next page: each relay's own oldest note, the newest of those, inclusive; no relay moving is the end", async () => {
  const { pageAfter } = await import("../src/net/notifications.js")
  const at = (...ts) => ts.map(t => ev(1, ALICE, [["p", ME]], "", t))
  // A busy relay's 100 reach back to 900; a quiet one's reach back to 100. Starting at 100 would skip 100..900 on the
  // busy one (the bug: the combined oldest), so the next page starts at 900.
  assert.deepEqual(pageAfter([at(1000, 950, 900), at(800, 100)]), { until: 900, done: false })
  assert.deepEqual(pageAfter([at(500, 300)], 400), { until: 300, done: false }, "moved past until")
  assert.deepEqual(pageAfter([at(400, 400)], 400), { until: null, done: true }, "only notes at until itself: no more")
  assert.deepEqual(pageAfter([at(400), at(300)], 400), { until: 300, done: false }, "one relay moving is enough")
  assert.deepEqual(pageAfter([[], []]), { until: null, done: true }, "empty pages")
})

test("fetch: each relay is asked on its own and the list shows once half have answered, not after the slowest", async () => {
  const { fetchNotificationEvents } = await import("../src/net/notifications.js")
  const a = ev(1, ALICE, [["p", ME]], "", 900), b = ev(7, BOB, [["p", ME]], "+", 800), c = ev(1, BOB, [["p", ME]], "", 700)
  let release
  const slow = new Promise(r => { release = r })
  const asked = []
  const query = async (relays, filter) => {
    asked.push([relays, filter])
    if (relays[0] === "wss://slow") { await slow; return [c] }
    return relays[0] === "wss://a" ? [a, b] : [b]
  }
  const shows = []
  const done = fetchNotificationEvents(ME, ["wss://a", "wss://b", "wss://slow", "wss://a"], { limit: 2, query, onEvents: evs => shows.push(evs.map(e => e.id)) })
  await new Promise(r => setTimeout(r, 20))
  assert.deepEqual(asked.map(([r]) => r), [["wss://a"], ["wss://b"], ["wss://slow"]], "one relay per ask, each once")
  assert.deepEqual(asked[0][1], { kinds: [1, 3, 6, 7, 16, 1068, 1111, 9802, 9735, 30023], "#p": [ME], limit: 2 }, "one filter object")
  assert.deepEqual(shows, [[a.id, b.id]], "shown with two of three in, the slow relay still out")
  release()
  const page = await done
  assert.deepEqual(page.events.map(e => e.id), [a.id, b.id, c.id])
  assert.deepEqual(shows.at(-1), [a.id, b.id, c.id], "the late relay's notes are shown when they come")
  assert.deepEqual([page.until, page.done], [800, false], "next page from the newest per-relay oldest")
})

test("fetch: with one fast relay of several slow ones, the list shows after firstMs; a forged receipt is dropped", async () => {
  const { fetchNotificationEvents } = await import("../src/net/notifications.js")
  const a = ev(1, ALICE, [["p", ME]], "", 900), forged = ev(9735, BOB, [["p", ME]], "", 850)
  const never = new Promise(() => {})
  const query = async relays => relays[0] === "wss://fast" ? [a, forged] : never
  const shows = []
  fetchNotificationEvents(ME, ["wss://fast", "wss://s1", "wss://s2"], { query, firstMs: 10, trust: async evs => evs.filter(e => e.kind !== 9735), onEvents: evs => shows.push(evs.map(e => e.id)) })
  await new Promise(r => setTimeout(r, 40))
  assert.deepEqual(shows, [[a.id]])
})

test("outside: not you, not whitelisted, not trusted; an empty trusted set counts nobody as outside", async () => {
  const { isOutside } = await import("../src/net/notifications.js")
  const trusted = new Set([BOB])
  assert.equal(isOutside(ALICE, ME, new Set(), trusted), true, "the control: a stranger once the graph is in")
  assert.equal(isOutside(ME, ME, new Set(), trusted), false, "the user")
  assert.equal(isOutside(ALICE, ME, new Set([ALICE]), trusted), false, "whitelisted")
  assert.equal(isOutside(BOB, ME, new Set(), trusted), false, "trusted")
  assert.equal(isOutside(ALICE, ME, new Set(), new Set()), false, "no graph yet")
})

test("trusted web: the people the follows' lists name, plus the follows; empty while no list names anyone", async () => {
  const { trustedWeb } = await import("../src/net/notifications.js")
  const lists = new Map([[BOB, { tags: [["p", CAROL], ["p", "nothex"], ["e", N1]] }]])
  assert.deepEqual([...trustedWeb([BOB], lists)].sort(), [BOB, CAROL].sort())
  assert.equal(trustedWeb([BOB], new Map()).size, 0, "no lists")
  assert.equal(trustedWeb([BOB], new Map([[BOB, { tags: [] }]])).size, 0, "lists that name nobody")
})

test("inside rows: a stranger's reply, mention, quote, article or highlight drops; their likes, reposts, zaps and follows stay", async () => {
  const { insideRows } = await import("../src/net/notifications.js")
  const types = ["reply", "mention", "quote", "article", "highlight", "reaction", "repost", "zap", "follow"]
  const rows = types.flatMap(type => [ALICE, BOB].map(who => ({ id: `${type}-${who}`, type, who: [who] })))
  const kept = insideRows(rows, ME, { trusted: new Set([BOB]) })
  assert.deepEqual(kept.filter(r => r.who[0] === ALICE).map(r => r.type), ["reaction", "repost", "zap", "follow"])
  assert.equal(kept.filter(r => r.who[0] === BOB).length, types.length)
  assert.equal(insideRows(rows, ME).length, rows.length, "no graph: nobody is outside")
  assert.equal(insideRows(rows, ME, { trusted: new Set([BOB]), whitelist: new Set([ALICE]) }).length, rows.length, "whitelisted")
})

test("inside rows before the graph is in: a follow's notes show, a stranger's wait, and likes, zaps and follows never wait", async () => {
  const { insideRows } = await import("../src/net/notifications.js")
  const types = ["reply", "mention", "quote", "article", "highlight", "reaction", "repost", "zap", "follow"]
  const rows = types.flatMap(type => [ALICE, BOB, ME].map(who => ({ id: `${type}-${who}`, type, who: [who] })))
  const kept = insideRows(rows, ME, { trusted: null, follows: [BOB] })
  assert.deepEqual(kept.filter(r => r.who[0] === ALICE).map(r => r.type), ["reaction", "repost", "zap", "follow"])
  assert.equal(kept.filter(r => r.who[0] === BOB).length, types.length)
  assert.equal(kept.filter(r => r.who[0] === ME).length, types.length, "the user's own")
})

test("about preview: @people stay, links to notes go, pictures become thumbnails, whitespace collapses", async () => {
  const { aboutPreview } = await import("../src/net/notifications.js")
  const { npubEncode, noteEncode } = await import("nostr-tools/nip19")
  const content = `gm  nostr:${npubEncode(ALICE)}, see\n nostr:${noteEncode(N1)} https://x.example/a.png https://x.example/a.png https://p.fips/b.jpg https://x.example/page`
  const { parts, images } = aboutPreview({ kind: 1, content, tags: [] })
  assert.deepEqual(parts, ["gm ", { pubkey: ALICE }, ", see https://x.example/page"])
  assert.deepEqual(images, ["https://x.example/a.png"], "once each, and no .fips name")
  assert.deepEqual(aboutPreview({ kind: 30023, content: "long body", tags: [["title", "My article"]] }), { parts: ["My article"], images: [] })
  assert.deepEqual(aboutPreview({ kind: 1, content: "https://x.example/only.jpg", tags: [] }), { parts: [], images: ["https://x.example/only.jpg"] })
})

test("reaction display: likes are a heart, dislikes a thumbs down, else the first emoji, text and shortcodes a heart", async () => {
  const { reactionDisplayEmoji } = await import("../src/net/notifications.js")
  for (const c of ["", "+", "+1", "❤", "❤️", " + "]) assert.equal(reactionDisplayEmoji(c), "❤️", JSON.stringify(c))
  assert.equal(reactionDisplayEmoji("-"), "👎")
  assert.equal(reactionDisplayEmoji("-1"), "👎")
  assert.equal(reactionDisplayEmoji("🔥"), "🔥")
  assert.equal(reactionDisplayEmoji("so 🤙 good"), "🤙", "the first emoji in text")
  assert.equal(reactionDisplayEmoji("👍🏽"), "👍🏽", "a skin tone stays with its emoji")
  assert.equal(reactionDisplayEmoji("1️⃣"), "1️⃣", "a keycap")
  assert.equal(reactionDisplayEmoji(":soapbox:"), "❤️", "a custom shortcode")
  assert.equal(reactionDisplayEmoji("123"), "❤️", "plain digits are not emoji")
  assert.equal(reactionDisplayEmoji(undefined), "❤️")
})

test("reaction summary: up to three different emoji, first seen first; a heart when none", async () => {
  const { reactionEmojiSummary } = await import("../src/net/notifications.js")
  assert.equal(reactionEmojiSummary(["🔥", "+", "🔥", "🤙", "😂", "👀"]), "🔥❤️🤙")
  assert.equal(reactionEmojiSummary(["+", ""]), "❤️")
  assert.equal(reactionEmojiSummary([]), "❤️")
  assert.equal(reactionEmojiSummary(["🔥", "🤙"], 1), "🔥")
})

test("grouping: a folded like row keeps every reaction's raw content, newest first", () => {
  const rows = groupNotifications([
    ev(7, ALICE, [["e", N1], ["p", ME]], "+", 10),
    ev(7, BOB, [["e", N1], ["p", ME]], "🔥", 30),
    ev(7, CAROL, [["e", N1], ["p", ME]], "", 20),
  ], ME)
  assert.deepEqual(rows[0].emojis, ["🔥", "", "+"])
  assert.deepEqual(groupNotifications([ev(1, ALICE, [["p", ME]], "hi")], ME)[0].emojis, [], "only reactions carry emoji")
})
