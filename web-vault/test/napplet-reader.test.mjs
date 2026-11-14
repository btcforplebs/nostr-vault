// Plan P4: the Reader napplet (Feed + Thread + Profile) and the Compose napplet. Their pure blocks (between the
// "---- pure" markers in each index.html) are run here as they ship; the shell side is reader-intents.js and bus.js.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { nip19 } from "nostr-tools"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents, linkTarget, readerOpenFor, COMPOSE_DONE } from "../src/napplet/reader-intents.js"

function pureOf(file, names) {
  const html = fs.readFileSync(new URL(`../napplets/${file}/index.html`, import.meta.url), "utf8")
  const block = html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))
  assert.ok(block.length > 100, `${file} has a pure block`)
  const box = {}
  vm.runInNewContext(`${block}\n;Object.assign(box, { ${names.join(", ")} })`, { box, Date, URL })
  return box
}
const R = pureOf("reader", ["tokenize", "decodeNostr", "rootOf", "parentOf", "reactionTags", "repostOf", "mergeNotes", "threadRows", "ago"])
const C = pureOf("compose", ["replyTags", "noteTemplate"])
const A = "a".repeat(64), B = "b".repeat(64), C1 = "c".repeat(64), D = "d".repeat(64), E = "e".repeat(64)
const ev = (id, tags = [], at = 1, extra = {}) => ({ id, pubkey: A, kind: 1, created_at: at, content: "", tags, ...extra })
const plain = x => JSON.parse(JSON.stringify(x))

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

test("compose reply tags: root, reply when not the root, author and everyone tagged, once each", () => {
  const top = ev(A, [["p", B]])
  assert.deepEqual(plain(C.replyTags(top)), [["e", A, "", "root"], ["p", A], ["p", B]])
  const deep = { ...ev(C1, [["e", A, "", "root"], ["e", B, "", "reply"], ["p", A], ["p", D]]), pubkey: E }
  assert.deepEqual(plain(C.replyTags(deep)), [["e", A, "", "root"], ["e", C1, "", "reply"], ["p", E], ["p", A], ["p", D]])
})

test("compose note: trimmed, hashtags as t tags, empty or too long sends nothing, reply only to a real note", () => {
  assert.deepEqual(plain(C.noteTemplate("  Hello #Nostr and #nostr #Zaps ", null)), { kind: 1, content: "Hello #Nostr and #nostr #Zaps", tags: [["t", "nostr"], ["t", "zaps"]] })
  assert.equal(C.noteTemplate("   ", null), null)
  assert.equal(C.noteTemplate("x".repeat(20001), null), null)
  assert.deepEqual(plain(C.noteTemplate("hi", { id: "nope" })).tags, [])
  assert.deepEqual(plain(C.noteTemplate("hi", ev(A))).tags, [["e", A, "", "root"], ["p", A]])
})

test("reader: reaction tags name the note, its author and kind; reposts unwrap only a whole note", () => {
  assert.deepEqual(plain(R.reactionTags(ev(B))), [["e", B], ["p", A], ["k", "1"]])
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

test("switch: Feed, Thread and other profiles swap only while napplets are on; own profile and the old screens stay", () => {
  const main = fs.readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  assert.match(main, /const readsInNapplet = \(route, other\) => nappletsOn\(\) && \(route === "feed" \|\| route === "thread" \|\| \(route === "profile" && !!other\)\)/)
  assert.match(main, /\{!reader && route === "feed" && <FeedScreen/)
  assert.match(main, /\{!reader && route === "thread" && <ThreadScreen/)
})
