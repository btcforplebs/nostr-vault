// The Live reader: what counts as on air and playable, who a stream is by, Following/Global, the zap.stream link,
// and the chat rows (a zap needs a signed request).
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { decode } from "nostr-tools/nip19"
import { parseStream, isOnAir, playableUrl, hostOf, isAdultStream, pickStreams, liveFilters, liveRelays, fetchStreams, streamLink, chatRows, chatFilter, chatRelays, startScope, normalizedRelay, STREAM_RELAY, CHAT_RELAYS, STALE_AFTER } from "../src/readers/live.js"

const A = "a".repeat(64), B = "b".repeat(64), S = "5".repeat(64), C_ = "c".repeat(64)
const NOW = 1_800_000_000
const HLS = "https://cdn.example/live/index.m3u8"
let n = 0
const stream = (o = {}) => ({ id: String(++n).padStart(64, "0"), kind: 30311, pubkey: o.pubkey ?? A, created_at: o.at ?? NOW - 60,
  content: "", tags: o.tags ?? [["d", o.d ?? `s${n}`], ["title", o.title ?? "Show"], ["status", o.status ?? "live"], ["streaming", o.url ?? HLS], ...(o.extra ?? [])] })

test("on air: live or no status, not past ends, republished within the hour", () => {
  assert.ok(isOnAir({ status: "live", createdAt: NOW - 10 }, NOW))
  assert.ok(isOnAir({ status: null, createdAt: NOW - 10 }, NOW))
  assert.ok(!isOnAir({ status: "ended", createdAt: NOW - 10 }, NOW))
  assert.ok(!isOnAir({ status: "live", createdAt: NOW - 10, ends: NOW }, NOW))
  assert.ok(isOnAir({ status: "live", createdAt: NOW - STALE_AFTER }, NOW))
  assert.ok(!isOnAir({ status: "live", createdAt: NOW - STALE_AFTER - 1 }, NOW))
})

test("playable: the first HLS playlist among the streaming tags, wherever it sits", () => {
  assert.equal(playableUrl([["streaming", "moq://x/y"], ["streaming", HLS]]), HLS)
  assert.equal(playableUrl([["streaming", "https://youtube.com/live/abc"]]), null)
  assert.equal(playableUrl([["streaming", "rtmp://x/live.m3u8"]]), null)
})

test("the host: a p tag marked Host, else the author; a service's stream follows its host", () => {
  assert.equal(hostOf(S, [["p", B, "", "Host"]]), B)
  assert.equal(hostOf(S, [["p", B, "", "Speaker"]]), S)
  const evs = [stream({ pubkey: S, extra: [["p", B, "", "host"]] }), stream({ pubkey: S, extra: [["p", B, "", "Guest"]] })]
  assert.equal(pickStreams(evs, { scope: "following", follows: [B], now: NOW }).length, 1, "a followed guest doesn't count")
})

test("adult: content-warning, an adult t tag or word, or 🔞", () => {
  assert.ok(isAdultStream([["content-warning", ""]]))
  assert.ok(isAdultStream([["L", "content-warning"]]))
  assert.ok(isAdultStream([["t", "NSFW"]]))
  assert.ok(isAdultStream([["title", "late show 🔞"]]))
  assert.ok(isAdultStream([["summary", "xxx party"]]))
  assert.ok(!isAdultStream([["title", "Sussex nudibranchs"]]))
})

test("picked: newest per address, playable and on air, Global without adult, blocked author or host gone", () => {
  const ended = stream({ d: "show", at: NOW - 30, status: "ended" }), announced = stream({ d: "show", at: NOW - 600 })
  const stale = stream({ at: NOW - STALE_AFTER - 5 }), page = stream({ url: "https://example.com/watch" })
  const adult = stream({ extra: [["t", "nsfw"]] }), ok = stream({ pubkey: B })
  const hosted = stream({ pubkey: S, extra: [["p", A, "", "Host"]] })
  const out = pickStreams([announced, ended, stale, page, adult, ok, hosted], { scope: "global", follows: [], blocked: new Set([A]), now: NOW })
  assert.deepEqual(out.map(s => s.id), [ok.id], "the ended edit replaced the announcement; the hosted one is blocked through its host")
  assert.equal(pickStreams([adult], { scope: "following", follows: [A], now: NOW }).length, 1, "Following shows a followed adult stream, as iOS does")
})

test("an ended edit replaces its own live announcement; a later re-announce brings it back", () => {
  const announced = stream({ pubkey: B, d: "show", at: NOW - 600 }), ended = stream({ pubkey: B, d: "show", at: NOW - 30, status: "ended" })
  assert.deepEqual(pickStreams([announced, ended], { scope: "global", follows: [], now: NOW }), [])
  assert.deepEqual(pickStreams([ended, announced], { scope: "global", follows: [], now: NOW }), [], "order of arrival doesn't matter")
  const back = stream({ pubkey: B, d: "show", at: NOW - 5 })
  assert.deepEqual(pickStreams([announced, ended, back], { scope: "global", follows: [], now: NOW }).map(s => s.id), [back.id])
})

test("Global with a web shows trusted hosts (adult included, as iOS); with none, everyone but adult", async () => {
  const trusted = stream({ pubkey: S, extra: [["p", B, "", "Host"]] }), stranger = stream({ pubkey: C_ }), adult = stream({ pubkey: B, extra: [["t", "nsfw"]] })
  const withWeb = await fetchStreams({ scope: "global", me: A, follows: [B], readRelays: [], now: NOW, trustOf: async () => new Set([A, B]), query: async () => [trusted, stranger, adult] })
  assert.deepEqual(withWeb.map(s => s.id).sort(), [trusted.id, adult.id].sort())
  const noWeb = await fetchStreams({ scope: "global", me: A, follows: [], readRelays: [], now: NOW, trustOf: async () => { throw new Error("asked") }, query: async () => [trusted, stranger, adult] })
  assert.deepEqual(noWeb.map(s => s.id).sort(), [trusted.id, stranger.id].sort())
})

test("filters: Following by author and #p; Global asks for everything; zap.stream's relay is always asked", () => {
  assert.deepEqual(liveFilters("following", [A]), [{ kinds: [30311], authors: [A], limit: 300 }, { kinds: [30311], "#p": [A], limit: 300 }])
  assert.deepEqual(liveFilters("global", []), [{ kinds: [30311], limit: 300 }])
  assert.deepEqual(liveFilters("following", []), [])
  assert.deepEqual(liveRelays(["wss://relay.damus.io/", STREAM_RELAY]), ["wss://relay.damus.io", STREAM_RELAY])
})

test("someone who follows nobody opens on Global until they pick", () => {
  assert.equal(startScope(null, []), "global")
  assert.equal(startScope(null, [A]), "following")
  assert.equal(startScope("following", []), "following")
})

test("a load asks every filter and keeps only what's live", async () => {
  const asked = [], one = stream(), gone = stream({ status: "ended" })
  const out = await fetchStreams({ scope: "following", follows: [A], readRelays: [], now: NOW, query: async (r, f) => { asked.push(f); return [one, gone] } })
  assert.equal(asked.length, 2)
  assert.equal(out.length, 1)
  assert.equal(await fetchStreams({ scope: "following", follows: [], readRelays: [], query: async () => { throw new Error("asked") } }), null)
})

test("Open in zap.stream: an naddr by the author, with at most two of the stream's relays", () => {
  const s = parseStream(stream({ pubkey: S, d: "room", extra: [["relays", "wss://one.example/", "wss://two.example", "https://not-a-relay", "wss://three.example"], ["p", A, "", "Host"]] }))
  assert.equal(s.host, A)
  assert.deepEqual(s.chatRelays, ["wss://one.example", "wss://two.example", "wss://three.example"])
  const d = decode(streamLink(s).replace("https://zap.stream/", "")).data
  assert.deepEqual(d, { kind: 30311, pubkey: S, identifier: "room", relays: ["wss://one.example", "wss://two.example"] })
  assert.equal(normalizedRelay("https://x"), null)
})

test("chat: messages and checked zaps, oldest first, blocked people out; a forged zap is dropped", () => {
  const sk = generateSecretKey(), payer = getPublicKey(sk)
  const s = parseStream(stream({ d: "room" }))
  const req = finalizeEvent({ kind: 9734, created_at: NOW, content: "great set", tags: [["p", A], ["a", s.address], ["amount", "21000"]] }, sk)
  const zap = { id: "z".repeat(64), kind: 9735, pubkey: S, created_at: NOW + 2, content: "", tags: [["p", A], ["a", s.address], ["description", JSON.stringify(req)]] }
  const forged = { ...zap, id: "f".repeat(64), tags: [["p", A], ["description", JSON.stringify({ ...req, content: "fake" })]] }
  const msg = { id: "m".repeat(64), kind: 1311, pubkey: B, created_at: NOW + 1, content: " hi ", tags: [["a", s.address]] }
  const blockedMsg = { ...msg, id: "x".repeat(64), pubkey: S, content: "spam" }
  const rows = chatRows([zap, forged, msg, blockedMsg, { ...msg, content: "  " , id: "e".repeat(64) }], new Set([S]))
  assert.deepEqual(rows.map(r => [r.who, r.text, r.sats]), [[B, "hi", 0], [payer, "great set", 21]])
  assert.deepEqual(chatFilter(s), { kinds: [1311, 9735], "#a": [s.address], limit: 200 })
  assert.deepEqual(chatRelays(s), CHAT_RELAYS)
})

test("nothing in the Live module writes to Haven", async () => {
  const src = (await import("node:fs")).readFileSync(new URL("../src/readers/live.js", import.meta.url), "utf8")
  assert.ok(!/vault|\.feed\.|\.outbox\.|publish\(/.test(src.replace(/^\s*(\/\/|\/\*\*|\*).*$/gm, "")))
})
