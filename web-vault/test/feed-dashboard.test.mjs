// The Feed Dashboard (parity #19): FeedDashboardSnapshot.build's rules ported (net/feed-dashboard.js), the filters one
// load asks, the load with mock relays, the iPhone's words and numbers, and opening a feed on Following.
// Throwaway keys only; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { AUTHORS_PER_FILTER, WINDOW_S, attachPopular, buildDashboard, compact, dashboardFilters, fetchDashboard, hasWavlakeTrack, newFollowersSince, oneLine, profilesOf } from "../src/net/feed-dashboard.js"
import { trustedReceipts } from "../src/net/zaps.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const now = 1_762_300_000, since = now - WINDOW_S
const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const [me, a, b, c, stranger, blockedOne] = Array.from({ length: 6 }, key)
const follows = new Set([a.pk, b.pk, c.pk, blockedOne.pk])
const sign = (who, kind, { content = "", tags = [], at = now - 60 } = {}) => finalizeEvent({ kind, content, tags, created_at: at }, who.sk)
const hex = n => n.toString(16).padStart(64, "0")

test("compact: FeedDashboardView.compact", () => {
  assert.deepEqual([0, 999, 1000, 1234, 9999, 10_000, 12_345, 1_234_567].map(compact), ["0", "999", "1.0k", "1.2k", "10.0k", "10k", "12k", "1.2M"])
})

test("oneLine: the first non-empty line, trimmed, 80 at most; Wavlake track links make Music", () => {
  assert.equal(oneLine("\n\n  Hello there  \nsecond"), "Hello there")
  assert.equal(oneLine("   "), null)
  assert.equal(oneLine("x".repeat(100)).length, 80)
  assert.equal(hasWavlakeTrack("listen https://wavlake.com/track/3f2a-bb now"), true)
  assert.equal(hasWavlakeTrack("https://wavlake.com/album/xyz"), false)
  assert.equal(hasWavlakeTrack("wavlake.com is nice"), false)
})

test("buildDashboard: posts, people, most active, trending (2+ people), popular (2+ follows), blocked and old left out", () => {
  const n1 = sign(a, 1, { content: "gm #Nostr", tags: [["t", "Nostr"], ["t", "bitcoin"]] })
  const events = [
    n1, n1, // the same event twice counts once
    sign(a, 1, { content: "second", tags: [["t", "x".repeat(41)]] }),
    sign(a, 6, { tags: [["e", hex(9)], ["p", stranger.pk]] }),
    sign(b, 1, { content: "#nostr too", tags: [["t", "nostr"], ["q", n1.id]] }),
    sign(c, 7, { content: "+", tags: [["e", hex(1)], ["e", n1.id]] }),
    sign(c, 7, { content: "-", tags: [["e", hex(9)]] }), // a dislike counts for nothing
    sign(b, 7, { content: "🔥", tags: [["e", hex(9)]] }),
    sign(c, 1, { content: "old", tags: [["t", "bitcoin"]], at: since - 1 }),
    sign(stranger, 1, { content: "not followed", tags: [["t", "bitcoin"]] }),
    sign(blockedOne, 1, { content: "blocked", tags: [["t", "bitcoin"]] }),
  ]
  const s = buildDashboard({ events, follows, owner: me.pk, blocked: new Set([blockedOne.pk]), since, now, newFollowers: 2 })
  assert.equal(s.posts, 4)
  assert.equal(s.activePeople, 2)
  assert.deepEqual(s.mostActive, [{ id: a.pk, count: 3 }, { id: b.pk, count: 1 }])
  assert.deepEqual(s.trending, [{ id: "nostr", count: 2 }])
  assert.deepEqual(s.popular.map(p => [p.id, p.people, !!p.note]), [[n1.id, 2, true], [hex(9), 2, false]].sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1)))
  assert.equal(s.newFollowers, 2)
  assert.deepEqual(profilesOf(s).sort(), [a.pk, b.pk].sort())
})

test("buildDashboard: tiles in the iPhone's order with a preview of the newest; recipes apart from articles; listings once", () => {
  const events = [
    sign(a, 1068, { content: "\nBest pizza?\nA or B", at: now - 100 }),
    sign(b, 1068, { content: "Older poll", at: now - 500 }),
    sign(a, 30023, { content: "body", tags: [["d", "x"], ["title", "My essay"]] }),
    sign(b, 30023, { content: "steps", tags: [["d", "y"], ["title", "Shakshuka"], ["t", "zapcooking"]] }),
    sign(c, 34236, { content: "", tags: [["d", "v"], ["alt", "A short video"]] }),
    sign(a, 1, { content: "🎵 https://wavlake.com/track/abc-123" }),
    sign(a, 30402, { content: "", tags: [["d", "chair"], ["title", "Old chair"], ["price", "10", "USD"], ["image", "https://img.example/c.jpg"]], at: now - 300 }),
    sign(a, 30402, { content: "", tags: [["d", "chair"], ["title", "Old chair, cheaper"], ["price", "8", "USD"], ["image", "https://img.example/c.jpg"]], at: now - 30 }),
  ]
  const s = buildDashboard({ events, follows, owner: me.pk, since, now })
  assert.deepEqual(s.tiles, [
    { feed: "polls", count: 2, preview: "Best pizza?" },
    { feed: "marketplace", count: 1, preview: "Old chair, cheaper" },
    { feed: "articles", count: 1, preview: "My essay" },
    { feed: "reels", count: 1, preview: "A short video" },
    { feed: "recipes", count: 1, preview: "Shakshuka" },
    { feed: "music", count: 1, preview: null },
  ])
  assert.equal(s.posts, 1) // the Wavlake note is still a post
})

test("buildDashboard: live streams of follows (author or host), on air and playable, newest per address, most viewers first", () => {
  const stream = (who, d, { host, viewers, status = "live", at = now - 120, url = "https://x.example/s.m3u8" } = {}) => sign(who, 30311, { at, tags: [
    ["d", d], ["title", `Show ${d}`], ["status", status], ["streaming", url], ...(host ? [["p", host, "", "host"]] : []),
    ...(viewers != null ? [["current_participants", String(viewers)]] : [])] })
  const events = [
    stream(a, "one", { viewers: 3, at: now - 600 }), stream(a, "one", { viewers: 5 }), // same address: newest kept
    stream(stranger, "hosted", { host: b.pk, viewers: 40 }), // a service's stream with a followed host
    stream(stranger, "theirs", {}), // nobody followed
    stream(c, "ended", { status: "ended" }),
    stream(c, "stale", { at: now - 2 * 3600 }),
    stream(stranger, "blockedhost", { host: blockedOne.pk }),
  ]
  const s = buildDashboard({ events, follows, owner: me.pk, blocked: new Set([blockedOne.pk]), since, now })
  assert.deepEqual(s.live.map(l => [l.identifier, l.viewers]), [["hosted", 40], ["one", 5]])
  assert.equal(s.live[0].host, b.pk)
})

test("buildDashboard: sats from receipts p-tagged to you in the window, each once, bolt11 only", () => {
  const receipt = (tags, at = now - 10) => ({ ...sign(stranger, 9735, { tags, at }) })
  const r1 = receipt([["p", me.pk], ["bolt11", "lnbc210n1pxyz"]])
  const zapReceipts = [r1, r1, receipt([["p", me.pk], ["bolt11", "lnbc1u1pxyz"]]), receipt([["p", a.pk], ["bolt11", "lnbc1u1p"]]),
    receipt([["p", me.pk], ["bolt11", "lnbc1u1p"]], since - 5), receipt([["p", me.pk], ["bolt11", "garbage"]])]
  assert.equal(buildDashboard({ zapReceipts, follows, owner: me.pk, since, now }).satsReceived, 21 + 100)
})

test("new followers: the lists this browser keeps, followed within the day", () => {
  assert.equal(newFollowersSince([{ pubkey: a.pk, at: now - 10 }, { pubkey: b.pk, at: since }, { pubkey: c.pk, at: since - 1 }], since), 2)
})

test("dashboardFilters: follows in chunks of 500, the iPhone's kinds and limits", () => {
  const many = Array.from({ length: 1201 }, (_, i) => hex(i + 1))
  const f = dashboardFilters({ follows: many, owner: me.pk, since })
  assert.equal(f.notes.length, 9)
  assert.deepEqual(f.notes.map(x => [x.kinds, x.limit, x.authors.length]).slice(0, 3), [[[1, 6], 1500, AUTHORS_PER_FILTER], [[1, 6], 1500, 500], [[1, 6], 1500, 201]])
  assert.deepEqual(f.notes[3].kinds, [7]); assert.deepEqual(f.notes[6].kinds, [1068, 30023, 34236]); assert.equal(f.notes[6].limit, 200)
  assert.ok(f.notes.every(x => x.since === since))
  assert.deepEqual(f.listings[0].kinds, [30018, 30020, 30402])
  assert.deepEqual(f.live.map(x => (x.authors ? "authors" : "#p")), ["authors", "authors", "authors", "#p", "#p", "#p"])
  assert.deepEqual(f.zaps, [{ kinds: [9735], "#p": [me.pk], since, limit: 500 }])
  assert.deepEqual(dashboardFilters({ follows: [], owner: "", since }), { notes: [], listings: [], live: [], zaps: [] })
})

test("fetchDashboard over mock relays: one answer per relay group, a dead relay gives nothing, popular notes fetched by id", async () => {
  const liked = sign(stranger, 1, { content: "an older banger", at: now - 3 * 86400 })
  // A receipt only counts sats when the payee's zap service published it and the request inside it verifies: this
  // dashboard load has no ctx, so the service can't be looked up and the receipt counts nothing (fails closed). The
  // second load looks the service up (it names `stranger`, the receipt's publisher) and counts it.
  const zapRequest = sign(a, 9734, { tags: [["p", me.pk]] })
  const asked = []
  const query = async (relays, f) => {
    asked.push({ relays, f })
    if (f.ids) return f.ids.includes(liked.id) ? [liked] : []
    if (f.kinds.includes(7)) return [sign(a, 7, { tags: [["e", liked.id]] }), sign(b, 7, { tags: [["e", liked.id]] })]
    if (f.kinds.includes(1)) return [sign(a, 1, { content: "hi" })]
    if (f.kinds.includes(30402)) throw new Error("relay down")
    if (f.kinds.includes(9735)) return [sign(stranger, 9735, { tags: [["p", me.pk], ["bolt11", "lnbc10u1p"], ["description", JSON.stringify(zapRequest)]] })]
    return []
  }
  const s = await fetchDashboard({ follows: [a.pk, b.pk], owner: me.pk, readRelays: ["wss://r1.example/", "wss://r2.example"], blocked: new Set(), now, query })
  assert.equal(s.posts, 1)
  assert.equal(s.satsReceived, 0, "no ctx: the zap service can't be checked, so nothing counts")
  const service = async () => ({ ok: true, url: "https://zaps.example/x", json: async () => ({ tag: "payRequest", callback: "https://zaps.example/cb", allowsNostr: true, nostrPubkey: stranger.pk }) })
  const checked = await fetchDashboard({ follows: [a.pk, b.pk], owner: me.pk, readRelays: ["wss://r1.example/"], blocked: new Set(), now, query,
    trust: evs => trustedReceipts(evs, async () => ({ lud16: "me@zaps.example" }), service) })
  assert.equal(checked.satsReceived, 1000)
  assert.deepEqual(s.popular.map(p => [p.id, p.people, p.note?.content]), [[liked.id, 2, "an older banger"]])
  assert.deepEqual(asked.find(x => x.f.kinds?.includes(1)).relays, ["wss://r1.example", "wss://r2.example"])
  assert.equal(asked.find(x => x.f.kinds?.includes(30311)).relays[0], "wss://relay.zap.stream")
  assert.ok(asked.find(x => x.f.kinds?.includes(30402)).relays.includes("wss://relay.damus.io"))
})

test("attachPopular drops a popular note no relay had", () => {
  const s = { popular: [{ id: "x", people: 3, note: null }, { id: "y", people: 2, note: null }] }
  assert.deepEqual(attachPopular(s, [{ id: "y", content: "found" }]).popular, [{ id: "y", people: 2, note: { id: "y", content: "found" } }])
})

test("the sheet's words: vault line, and a tile opens its feed on Following (diVines too, since #17)", async () => {
  const store = new Map()
  globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) }
  const { openOnFollowing, vaultLine } = await import("../src/components/FeedDashboard.jsx")
  assert.equal(vaultLine({ events: 12_345, wot: 1234 }), "12k events · Web of Trust 1.2k")
  assert.equal(vaultLine({ events: 5, wot: 0 }), "5 events")
  assert.equal(vaultLine({ events: null, wot: 0 }), "Counting events…")
  const picked = []
  for (const f of ["recipes", "polls", "live", "marketplace", "music", "articles"]) assert.equal(openOnFollowing(f, c => picked.push(c.mode)), true)
  assert.deepEqual(picked, ["recipes", "polls", "live", "marketplace", "music", "articles"])
  assert.equal(openOnFollowing("reels", c => picked.push(c.mode)), true)
  assert.equal(picked.at(-1), "reels")
  const scopes = [...store].filter(([, v]) => v === "following").map(([k]) => k)
  assert.equal(scopes.length, 5)
  assert.ok(scopes.includes("nv-reels-scope"))
})

test("the feed menu offers Dashboard just above Edit Feeds", async () => {
  const src = readFileSync(new URL("../src/components/FeedPickerMenu.jsx", import.meta.url), "utf8")
  assert.ok(src.indexOf("<span>Dashboard</span>") > 0 && src.indexOf("<span>Dashboard</span>") < src.indexOf("<span>Edit Feeds</span>"))
})
