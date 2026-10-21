import test from "node:test"
import assert from "node:assert/strict"
import { parsePoll, tally, share, voteTags, pollRelays, isPublicRelay, isClosed } from "../src/components/polls.js"

const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)
const pollEv = (tags, extra = {}) => ({ id: "p".repeat(64), pubkey: A, kind: 1068, content: " Which? ", created_at: 100, tags, ...extra })
const vote = (pubkey, picks, created_at = 200, id = pubkey + created_at) => ({ id, pubkey, kind: 1018, created_at, tags: [["e", "p".repeat(64)], ...picks.map(p => ["response", p])] })

test("a poll is read as the iPhone reads it (NIP88Poll.Poll)", () => {
  const p = parsePoll(pollEv([["option", "x", "Yes"], ["option", "y", "No"], ["option", "x", "dup"], ["option", "z", " "], ["polltype", "multiplechoice"], ["endsAt", "500"], ["relay", "wss://r.example"]]))
  assert.equal(p.question, "Which?")
  assert.deepEqual(p.options.map(o => o.id), ["x", "y"])
  assert.equal(p.multiple, true); assert.equal(p.endsAt, 500)
  assert.equal(isClosed(p, 499), false); assert.equal(isClosed(p, 500), true)
  assert.equal(parsePoll(pollEv([])), null)
  assert.equal(parsePoll({ ...pollEv([["option", "x", "Yes"]]), kind: 1 }), null)
})

test("one vote per person, their newest, only known options, nothing after it closes", () => {
  const single = parsePoll(pollEv([["option", "x", "Yes"], ["option", "y", "No"], ["endsAt", "1000"]]))
  const t = tally([vote(A, ["x"], 200), vote(A, ["y"], 300), vote(B, ["x", "y"], 210), vote(C, ["x"], 2000), vote(C, ["nope"], 220)], single, { now: 900 })
  assert.deepEqual([...t.voters].sort(), [A, B])
  assert.deepEqual(t.picks.get(A), ["y"])
  assert.deepEqual(t.picks.get(B), ["x"], "single choice counts the first pick")
  assert.equal(share(t, "x"), 0.5)
  assert.equal(tally([vote(A, ["x"])], single, { now: 900, blocked: new Set([A]) }).voters.size, 0)
  const future = tally([vote(A, ["x"], 900 + 601)], parsePoll(pollEv([["option", "x", "Yes"]])), { now: 900 })
  assert.equal(future.voters.size, 0, "a vote dated past clock drift doesn't count")
})

test("vote tags and relays", () => {
  const p = parsePoll(pollEv([["option", "x", "Yes"], ["option", "y", "No"], ["relay", "wss://192.168.1.2"], ["relay", "wss://good.example/"]]))
  assert.deepEqual(voteTags(p, ["y", "x", "zz"], "wss://h"), [["e", p.id, "wss://h"], ["p", A], ["response", "y"]])
  assert.deepEqual(pollRelays(p, ["wss://good.example", "wss://mine.example"]), ["wss://good.example/", "wss://mine.example"])
  for (const bad of ["wss://localhost", "ws://10.0.0.2", "wss://x.onion", "https://a.b", "wss://172.20.1.1"]) assert.equal(isPublicRelay(bad), false, bad)
})

test("a highlight's source: article, then note, then web page", async () => {
  const { registerHooks } = await import("node:module")
  const { readFileSync } = await import("node:fs")
  const { fileURLToPath } = await import("node:url")
  const { transformSync } = await import("rolldown/utils")
  registerHooks({ load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    return { format: "module", source: code, shortCircuit: true }
  } })
  const { highlightSource, hasKindBody } = await import("../src/components/FeedKinds.jsx")
  assert.deepEqual(highlightSource([["a", `30023:${A}:my-post`], ["e", B], ["r", "https://x.example"]]).q, { type: "addr", kind: 30023, pubkey: A, d: "my-post", relays: [] })
  assert.deepEqual(highlightSource([["e", B], ["r", "https://x.example"]]).q, { type: "note", id: B, relays: [] })
  assert.deepEqual(highlightSource([["r", "https://x.example/p"]]), { url: "https://x.example/p" })
  assert.equal(highlightSource([["r", "javascript:alert(1)"]]), null)
  assert.equal(hasKindBody({ kind: 30023 }) && hasKindBody({ kind: 9802 }) && hasKindBody({ kind: 1068 }) && !hasKindBody({ kind: 1 }), true)
})

test("link cards: web links only, once each, three at most; translate offers only another language", async () => {
  const { cardLinks } = await import("../src/components/NoteText.jsx")
  const parts = ["a ", "https://x.example/a", " b ", "https://x.example/p.jpg", " ", "nostr:npub1x", " ", "https://x.example/a", " ", "https://y.example", " ", "https://z.example", " ", "https://w.example", ""]
  assert.deepEqual(cardLinks(parts), ["https://x.example/a", "https://y.example", "https://z.example"])
  const { translatable, shouldOffer } = await import("../src/components/TranslateButton.jsx")
  assert.equal(translatable("Hola amigos https://x.example/a nostr:npub1abc  que tal"), "Hola amigos que tal")
  assert.equal(shouldOffer("es", "en"), true)
  assert.equal(shouldOffer("en-GB", "en"), false)
  assert.equal(shouldOffer(null, "en"), false)
  assert.equal(shouldOffer("und", "en"), false)
})

test("Event Info lists your relays once, ticks the write ones, and sends only the signed fields", async () => {
  const { infoRelays, signedFields, kindName } = await import("../src/components/EventInfo.jsx")
  const { relays, ticked } = infoRelays({ relays: { read: ["wss://a.example/", "wss://b.example"], write: ["wss://b.example/", "wss://c.example", "https://nope"] } })
  assert.deepEqual(relays, ["wss://a.example", "wss://b.example", "wss://c.example"])
  assert.deepEqual([...ticked].filter(r => relays.includes(r)), ["wss://b.example", "wss://c.example"])
  const ev = { id: "1", pubkey: "2", created_at: 3, kind: 1, tags: [], content: "x", sig: "s", seenOn: ["r"], _local: true }
  assert.deepEqual(Object.keys(signedFields(ev)), ["id", "pubkey", "created_at", "kind", "tags", "content", "sig"])
  assert.equal(kindName(30023), "Article"); assert.equal(kindName(4242), "Event")
})

test("how a reaction shows on the Like button (reactionDisplayEmoji)", async () => {
  const { displayEmoji, firstEmoji } = await import("../src/components/ReactionButton.jsx")
  for (const c of ["", "+", "+1", "❤", "❤️"]) assert.equal(displayEmoji(c), "❤️", JSON.stringify(c))
  assert.equal(displayEmoji("-"), "👎")
  assert.equal(displayEmoji("🔥🔥"), "🔥")
  assert.equal(displayEmoji("👍🏽"), "👍🏽")
  assert.equal(displayEmoji(":shaka:"), "❤️")
  assert.equal(firstEmoji("hello"), ""); assert.equal(firstEmoji(" 🇺🇸 "), "🇺🇸")
})
