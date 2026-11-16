// Plan P4: the Reader napplet (Feed + Thread + Profile) and the Compose napplet. Their pure blocks (between the
// "---- pure" markers in each index.html) are run here as they ship; the shell side is reader-intents.js and bus.js.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { nip19 } from "nostr-tools"
import { createBus } from "../src/napplet/bus.js"
import { mediaViewOf } from "../src/napplet/media-view.js"
import { hashtags } from "../src/net/hashtags.js"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { readerIntents, linkTarget, readerOpenFor, previewCard, feedTagOf, COMPOSE_DONE } from "../src/napplet/reader-intents.js"

function pureOf(file, names) {
  const html = fs.readFileSync(new URL(`../napplets/${file}/index.html`, import.meta.url), "utf8")
  const block = html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))
  assert.ok(block.length > 100, `${file} has a pure block`)
  const box = {}
  vm.runInNewContext(`${block}\n;Object.assign(box, { ${names.join(", ")} })`, { box, Date, URL })
  return box
}
const R = pureOf("reader", ["inlineMarks", "MARKS", "cardLinks", "withoutCards", "hostOf", "tokenize", "decodeNostr", "rootOf", "parentOf", "repostOf", "mergeNotes", "threadRows", "ago"])
const C = pureOf("compose", ["replyTags", "noteTemplate", "quoteOf", "imetaTag", "neventOf"])
const A = "a".repeat(64), B = "b".repeat(64), C1 = "c".repeat(64), D = "d".repeat(64), E = "e".repeat(64)
const ev = (id, tags = [], at = 1, extra = {}) => ({ id, pubkey: A, kind: 1, created_at: at, content: "", tags, ...extra })
const plain = x => JSON.parse(JSON.stringify(x))
const H = c => c.repeat(64)

test("tokenize: links, pictures, video, hashtags, nostr: mentions and notes; punctuation stays text", () => {
  const npub = nip19.npubEncode(B), note = nip19.noteEncode(C1), nevent = nip19.neventEncode({ id: D, relays: ["wss://r.example"] }), nprofile = nip19.nprofileEncode({ pubkey: E, relays: ["wss://r.example"] })
  const parts = plain(R.tokenize(`hi nostr:${npub}, see https://x.example/a. pic https://x.example/p.jpg #Nostr nostr:${note} nostr:${nevent} nostr:${nprofile} https://v.example/v.mp4`))
  assert.deepEqual(parts.filter(p => p.t !== "text"), [
    { t: "profile", v: B }, { t: "link", v: "https://x.example/a" }, { t: "image", v: "https://x.example/p.jpg" }, { t: "tag", v: "Nostr" },
    { t: "note", v: C1 }, { t: "note", v: D }, { t: "profile", v: E }, { t: "video", v: "https://v.example/v.mp4" },
  ])
  assert.ok(parts.some(p => p.t === "text" && p.v.startsWith(", see")))
  assert.ok(parts.some(p => p.t === "text" && p.v.startsWith(". pic")))
})

test("tokenize: a broken nostr: reference stays text; no javascript: links", () => {
  const parts = plain(R.tokenize("nostr:npub1qqqq javascript:alert(1)"))
  assert.ok(parts.every(p => p.t === "text"))
  assert.equal(R.decodeNostr("nsec1" + "q".repeat(58)), null)
})

test("NIP-10: root and parent from marked tags, from old positional tags, and none", () => {
  const marked = ev(C1, [["e", A, "", "root"], ["e", B, "", "reply"]])
  assert.equal(R.rootOf(marked), A); assert.equal(R.parentOf(marked), B)
  const rootOnly = ev(C1, [["e", A, "", "root"]])
  assert.equal(R.parentOf(rootOnly), A)
  const positional = ev(C1, [["e", A], ["e", B]])
  assert.equal(R.rootOf(positional), A); assert.equal(R.parentOf(positional), B)
  assert.equal(R.rootOf(ev(C1)), C1); assert.equal(R.parentOf(ev(C1)), null)
})

test("compose: reply tags, quotes and imeta are the classic composer's own (net/actions.js, net/upload.js)", async () => {
  const { replyTags, quoteOf } = await import("../src/net/actions.js")
  const { imetaTag } = await import("../src/net/upload.js")
  const parents = [ev(A, [["p", B]]), { ...ev(C1, [["e", A, "", "root", B], ["e", B, "", "reply"], ["p", A], ["p", D]]), pubkey: E }, ev(D, [["e", A], ["e", B, "", "mention"], ["p", A]])]
  for (const p of parents) assert.deepEqual(plain(C.replyTags(p)), replyTags(p))
  const q = { ...ev(B, [], 7), kind: 1, pubkey: E }
  assert.deepEqual(plain(C.quoteOf(q, "look")), quoteOf(q, "look"))
  const m = { url: "https://x.example/a.jpg", mime: "image/jpeg", sha256: H("f"), size: 99 }
  assert.deepEqual(plain(C.imetaTag(m)), imetaTag(m))
})

test("compose note: trimmed, hashtags as t tags, a quote's line and q tag, files' links and imeta; nothing to send is null", () => {
  assert.deepEqual(plain(C.noteTemplate("  Hello #Nostr and #nostr #Zaps ", null)), { kind: 1, content: "Hello #Nostr and #nostr #Zaps", tags: [["t", "nostr"], ["t", "zaps"]] })
  assert.equal(C.noteTemplate("   ", null), null)
  assert.equal(C.noteTemplate("x".repeat(20001), null), null)
  assert.deepEqual(plain(C.noteTemplate("hi", { id: "nope" })).tags, [])
  const q = { ...ev(B), pubkey: E }
  const quoted = plain(C.noteTemplate("look", null, { quote: q }))
  assert.match(quoted.content, /^look\nnostr:nevent1[02-9ac-hj-np-z]+$/)
  assert.deepEqual(quoted.tags, [["q", B, "", E], ["p", E]])
  assert.match(plain(C.noteTemplate("", null, { quote: q })).content, /^nostr:nevent1/) // a quote alone
  const withFile = plain(C.noteTemplate("pic", null, { media: [{ url: "https://x.example/a.jpg", mime: "image/jpeg" }, { url: "http://bad.example/b.jpg" }] }))
  assert.equal(withFile.content, "pic\nhttps://x.example/a.jpg")
  assert.deepEqual(withFile.tags, [["imeta", "url https://x.example/a.jpg", "m image/jpeg"]])
})

test("reader: reposts unwrap only a whole note (a Like's tags are the shell's now: napplet:note/like)", () => {
  const inner = ev(C1, [], 5, { content: "hi" })
  assert.equal(R.repostOf({ kind: 6, content: JSON.stringify(inner) }).id, C1)
  assert.equal(R.repostOf({ kind: 6, content: "{\"id\":\"x\"}" }), null)
  assert.equal(R.repostOf({ kind: 1, content: JSON.stringify(inner) }), null)
})

test("reader: feed rows newest first, once each, capped", () => {
  const rows = R.mergeNotes([ev(A, [], 1)], [ev(B, [], 3), ev(A, [], 1), ev(C1, [], 2), { id: "bad", created_at: 9 }], 2)
  assert.deepEqual(plain(rows.map(r => r.id)), [B, C1])
})

test("reader: thread rows put each reply under the note it answers, oldest first, an orphan under the root", () => {
  const root = ev(A, [], 1), r1 = ev(B, [["e", A, "", "root"]], 3), r2 = ev(C1, [["e", A, "", "root"], ["e", B, "", "reply"]], 4)
  const early = ev(D, [["e", A, "", "root"]], 2), orphan = ev(E, [["e", A, "", "root"], ["e", "f".repeat(64), "", "reply"]], 5)
  assert.deepEqual(plain(R.threadRows(A, [orphan, r2, r1, root, early]).map(r => [r.ev.id[0], r.depth])), [["a", 0], ["d", 1], ["b", 1], ["c", 2], ["e", 1]])
})

test("link intent: http(s) only, no credentials, bounded", () => {
  assert.equal(linkTarget("https://example.com/a?b=1"), "https://example.com/a?b=1")
  for (const bad of ["javascript:alert(1)", "data:text/html,x", "https://u:p@example.com", "file:///etc/passwd", "x".repeat(10), "https://e.com/" + "a".repeat(2050), 5]) assert.equal(linkTarget(bad), null)
})

test("routes: a thread or someone's profile opens in the Reader; anything else is the feed", () => {
  assert.deepEqual(readerOpenFor("thread", A), { archetype: "note", action: "open", payload: { id: A } })
  assert.deepEqual(readerOpenFor("profile", B), { archetype: "profile", action: "open", payload: { pubkey: B } })
  assert.equal(readerOpenFor("feed", ""), null)
  assert.equal(readerOpenFor("thread", "zz"), null)
})

test("bus: Reader's compose ask opens Compose and delivers the note; link/open is the shell's, never a napplet's; done closes", async () => {
  const bus = createBus(), sent = [], opened = []
  const compose = { dTag: "nv-compose", send: m => sent.push(m) }
  let done = 0
  const wire = readerIntents({ bus, openCompose: async () => compose, onComposeDone: () => done++, openUrl: u => opened.push(u) })
  const reader = { dTag: "nv-reader", send: () => {} }
  const r = await bus.invoke(reader, { archetype: "compose", action: "reply", payload: { event: ev(A) } })
  assert.equal(r.ok, true)
  assert.equal(sent[0].type, "intent.deliver")
  assert.equal(sent[0].delivery.payload.event.id, A)
  assert.equal(sent[0].delivery.action, "reply")
  assert.equal((await bus.invoke(reader, { archetype: "link", action: "open", payload: { url: "javascript:alert(1)" } })).ok, false)
  assert.equal((await bus.invoke(reader, { archetype: "link", action: "open", payload: { url: "https://example.com" } })).ok, true)
  assert.deepEqual(opened, ["https://example.com/"])
  bus.emit(compose, COMPOSE_DONE, { sent: true })
  assert.equal(done, 1)
  wire.close()
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "new" })).ok, false)
})

test("link cards: up to 3 page links (no pictures, video, .fips, repeats) leave the text, the rest joined and trimmed", () => {
  const parts = R.tokenize("Read https://a.example/x and https://b.example, pic https://a.example/p.jpg https://a.example/x https://m.fips/y https://c.example https://d.example\n")
  assert.deepEqual(plain(R.cardLinks(parts)), ["https://a.example/x", "https://b.example", "https://c.example"])
  const left = plain(R.withoutCards(parts, R.cardLinks(parts)))
  assert.deepEqual(left.filter(p => p.t !== "text").map(p => p.v), ["https://a.example/p.jpg", "https://m.fips/y", "https://d.example"])
  assert.equal(left[0].v, "Read  and , pic ")
  assert.equal(left.at(-1).v.endsWith("\n"), false)
  assert.deepEqual(plain(R.withoutCards(R.tokenize("only text"), [])), [{ t: "text", v: "only text" }])
  assert.deepEqual(plain(R.withoutCards(R.tokenize("  https://a.example  "), ["https://a.example"])), [])
  assert.equal(R.hostOf("https://www.Example.com/a"), "example.com")
})

test("link/preview: the shell reads the page for the Reader only and hands back just the card's strings", async () => {
  const bus = createBus(), asked = []
  const wire = readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {},
    preview: async url => { asked.push(url); return url.includes("none") ? null : { title: "T", description: "D", siteName: "S", image: "https://i.example/p.png", extra: "x" } } })
  const reader = { dTag: "nv-reader", send: () => {} }, other = { dTag: "nv-messages", send: () => {} }
  const r = await bus.invoke(reader, { archetype: "link", action: "preview", payload: { url: "https://a.example/x" } })
  assert.equal(r.ok, true)
  assert.deepEqual(r.data, { title: "T", description: "D", siteName: "S", image: "https://i.example/p.png" })
  assert.equal((await bus.invoke(reader, { archetype: "link", action: "preview", payload: { url: "https://none.example" } })).data, null)
  assert.equal((await bus.invoke(reader, { archetype: "link", action: "preview", payload: { url: "javascript:alert(1)" } })).ok, false)
  assert.equal((await bus.invoke(other, { archetype: "link", action: "preview", payload: { url: "https://a.example/y" } })).ok, false)
  assert.deepEqual(asked, ["https://a.example/x", "https://none.example/"])
  wire.close()
})

test("previewCard: needs a title; strings only, cut to 300; the picture https only", () => {
  assert.equal(previewCard(null), null)
  assert.equal(previewCard({ description: "no title" }), null)
  assert.deepEqual(previewCard({ title: "x".repeat(400), description: 5, image: "http://plain.example/p.png" }), { title: "x".repeat(300), description: null, siteName: null, image: null })
})

test("bus: a shell-answered intent's data rides back; none when it has no data", async () => {
  const bus = createBus(), who = { dTag: "a", send: () => {} }
  bus.register({ id: "x", title: "x", archetype: "t", actions: ["with", "without"], conventions: [], deliver: p => (p?.d ? { ok: true, data: { n: 1 } } : { ok: true }) })
  assert.deepEqual((await bus.invoke(who, { archetype: "t", action: "with", payload: { d: 1 } })).data, { n: 1 })
  assert.equal("data" in (await bus.invoke(who, { archetype: "t", action: "without", payload: {} })), false)
})

test("media/view: the shell opens its viewer over the signed note's own media, at the tapped picture", async () => {
  const sk = generateSecretKey()
  const note = finalizeEvent({ kind: 1, created_at: 1, content: "two https://p.example/a.jpg, https://p.example/b.png and https://x.example/page", tags: [["imeta", "url https://p.example/c.webp", "m image/webp"]] }, sk)
  const bus = createBus(), shown = []
  const wire = readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent, onMedia: v => shown.push(v) })
  const reader = { dTag: "nv-reader", send: () => {} }
  const r = await bus.invoke(reader, { archetype: "media", action: "view", payload: { event: note, url: "https://p.example/b.png" } })
  assert.equal(r.ok, true)
  assert.deepEqual(shown[0].items.map(m => m.url), ["https://p.example/a.jpg", "https://p.example/b.png", "https://p.example/c.webp"])
  assert.equal(shown[0].start, 1)
  assert.equal(shown[0].author, note.pubkey)
  // an address the note doesn't carry, or a note whose text was changed after signing: refused, nothing opens
  assert.equal((await bus.invoke(reader, { archetype: "media", action: "view", payload: { event: note, url: "https://evil.example/x.jpg" } })).ok, false)
  assert.equal((await bus.invoke(reader, { archetype: "media", action: "view", payload: { event: { ...note, content: note.content + " https://evil.example/x.jpg" }, url: "https://evil.example/x.jpg" } })).ok, false)
  assert.equal(shown.length, 1)
  wire.close()
})

test("mediaViewOf: trailing punctuation off the link; no media or no match -> null", () => {
  assert.deepEqual(mediaViewOf({ content: "see https://p.example/a.jpg.", tags: [] }, "https://p.example/a.jpg"), { items: [{ url: "https://p.example/a.jpg", type: "image" }], start: 0 })
  assert.equal(mediaViewOf({ content: "text only", tags: [] }, "https://p.example/a.jpg"), null)
  assert.equal(mediaViewOf(null, "https://p.example/a.jpg"), null)
})

test("marks: the Reader's inline marks are the classic note text's, rule for rule", async () => {
  const classic = await import("../src/net/inline-md.js")
  const src = fs.readFileSync(new URL("../src/net/inline-md.js", import.meta.url), "utf8")
  assert.equal(R.MARKS.source, /const RE = \/(.+)\/g\n/.exec(src)[1], "same expression as inline-md.js")
  for (const t of ["**bold** and __b__", "*it* _it_ snake_case_word", "~~gone~~ `x = 1`", "plain", "a * b * c", "**unclosed"])
    assert.deepEqual(plain(R.inlineMarks(t)), classic.inlineMarks(t), t)
})

test("hashtags: classic rules (not after a letter or digit, needs a letter, <= 64); a link's #fragment stays the link", () => {
  const tags = t => plain(R.tokenize(t)).filter(p => p.t === "tag").map(p => p.v)
  const line = "#Nostr C#sharp a#b #1 #2024plans #_x #ünïcode"
  assert.deepEqual(tags(line), ["Nostr", "2024plans", "_x", "ünïcode"])
  assert.deepEqual(tags(line).map(t => t.toLowerCase()), hashtags(line), "same tags as the classic hashtags()")
  assert.deepEqual(tags("#" + "a".repeat(64) + " #" + "b".repeat(65)), ["a".repeat(64)])
  assert.deepEqual(tags("https://x.example/page#section"), [])
})

test("feed/open with a tag: #/feed?tag= opens the tag in the Reader; anything else is no tag", () => {
  assert.deepEqual(readerOpenFor("feed", "", "#/feed?tag=Bitcoin"), { archetype: "feed", action: "open", payload: { tag: "bitcoin" } })
  assert.deepEqual(readerOpenFor("feed", "", "#/feed?tag=%23Nostr&x=1"), { archetype: "feed", action: "open", payload: { tag: "nostr" } })
  assert.equal(readerOpenFor("feed", "", "#/feed"), null)
  assert.equal(readerOpenFor("feed", "", "#/feed?note=" + "a".repeat(64)), null)
  assert.equal(feedTagOf("#/feed?tag=two words"), "")
  assert.equal(feedTagOf("#/feed?tag=" + "x".repeat(65)), "")
  assert.equal(readerOpenFor("search", "", "#/search?tag=x"), null)
})

test("profile/show: a name tapped in the Reader opens the app's full profile; only a real pubkey", async () => {
  const bus = createBus(), shown = []
  const wire = readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, onProfile: pk => shown.push(pk) })
  const reader = { dTag: "nv-reader", send: () => {} }
  assert.equal((await bus.invoke(reader, { archetype: "profile", action: "show", payload: { pubkey: B } })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "profile", action: "show", payload: { pubkey: "x" } })).ok, false)
  assert.deepEqual(shown, [B])
  wire.close()
  // no onProfile given (another shell): no handler, so the Reader opens its own small profile
  const bus2 = createBus()
  readerIntents({ bus: bus2, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {} })
  assert.equal((await bus2.invoke(reader, { archetype: "profile", action: "show", payload: { pubkey: B } })).ok, false)
})

test("plan step 11: the desktop's Feed and threads are the Reader, someone's profile stays the full one; the phone keeps its screens", () => {
  const main = fs.readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  const desk = fs.readFileSync(new URL("../src/desktop/DesktopShell.jsx", import.meta.url), "utf8")
  assert.match(main, /setDeskLayout\(mode !== "phone"\)/)
  assert.doesNotMatch(main, /ReaderPane|nappletsOn/, "the phone layout has no napplets")
  assert.match(main, /\{route === "profile" && \(other \? <PersonScreen/)
  assert.match(main, /\{route === "feed" && <FeedScreen/)
  assert.match(main, /\{route === "thread" && <ThreadScreen/)
  assert.match(desk, /\{other \? <PersonScreen key=\{view\.arg\} ctx=\{ctx\} pubkey=\{view\.arg\} \/>/, "someone's profile: the full classic one")
  assert.doesNotMatch(desk, /FeedScreen|ThreadScreen|nappletsOn/)
})
