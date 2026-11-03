// The left rail's favourites (src/desktop/rail/rail-favs.js), the Feed links they open (net/feeds.js linkChoice), list
// feeds (net/list-feed.js) and the layout's vault sync (net/space-sync.js, desktop/space/layout-store.js).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { cleanFav, defaultRail, favHref, favKey, isPinned, missingSections, moveFav, moveFavBefore, normalizeRail, normalizeRelay, pin, relayName, sameRail, shownFavs, unpin, MAX_FAVS, SECTION_IDS } from "../src/desktop/rail/rail-favs.js"
import { linkChoice, feedRelays, feedKey, fetchStrangerFeed, liveFilters, liveKeeps, FEEDS } from "../src/net/feeds.js"
import { listName, listPeople, myLists, newestLists, resolveList } from "../src/net/list-feed.js"
import { isLayoutEvent, layoutTemplate, newerLayout, newestEvent, parseLayout, pullLayout, pushLayout, SYNC_KIND, SYNC_TAGS } from "../src/net/space-sync.js"
import { SYNC_D, defaultLayout } from "../src/desktop/space/space-layout.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"

const A = "a".repeat(64), B = "b".repeat(64)
const FEED_IDS = FEEDS.map(f => f.id)
const keys = r => r.map(favKey)

test("the default rail is the six sections in Tod's order", () => {
  assert.deepEqual(SECTION_IDS, ["feed", "search", "messages", "wot", "vault", "profile"])
  assert.deepEqual(defaultRail(), SECTION_IDS.map(id => ({ type: "section", id })))
})

test("cleanFav keeps good favourites, drops broken ones, keeps a newer app's type", () => {
  assert.deepEqual(cleanFav({ type: "hashtag", tag: "#Bitcoin" }), { type: "hashtag", tag: "bitcoin" })
  assert.equal(cleanFav({ type: "hashtag", tag: "two words" }), null)
  assert.equal(cleanFav({ type: "person", pubkey: "xyz" }), null)
  assert.deepEqual(cleanFav({ type: "relay", url: " wss://nos.lol/ " }), { type: "relay", url: "wss://nos.lol" })
  assert.equal(cleanFav({ type: "relay", url: "https://nos.lol" }), null)
  assert.deepEqual(cleanFav({ type: "list", pubkey: A, d: "friends", name: "  Friends " }), { type: "list", pubkey: A, d: "friends", name: "Friends" })
  assert.equal(cleanFav({ type: "list", pubkey: A, d: "" }), null)
  assert.deepEqual(cleanFav({ type: "zaps-board", x: 1 }), { type: "zaps-board", x: 1 })
  for (const bad of [null, 3, {}, { type: "" }]) assert.equal(cleanFav(bad), null)
  assert.equal(normalizeRelay("ws://127.0.0.1:4869"), "ws://127.0.0.1:4869")
  assert.equal(relayName("wss://relay.damus.io"), "damus.io")
})

test("each favourite opens its place", () => {
  assert.equal(favHref({ type: "section", id: "wot" }), "#/wot")
  assert.equal(favHref({ type: "feed", mode: "articles" }), "#/feed?feed=articles")
  assert.equal(favHref({ type: "person", pubkey: A }), `#/profile/${A}`)
  assert.equal(favHref({ type: "hashtag", tag: "nostr" }), "#/feed?tag=nostr")
  assert.equal(favHref({ type: "list", pubkey: A, d: "a b" }), `#/feed?list=${A}:a%20b`)
  assert.equal(favHref({ type: "relay", url: "wss://nos.lol" }), "#/feed?relay=wss%3A%2F%2Fnos.lol")
  assert.equal(favHref({ type: "zaps-board" }), null)
})

test("normalizeRail: junk is the default, repeats drop out, Feed is always there, capped", () => {
  for (const bad of [null, "x", {}]) assert.deepEqual(normalizeRail(bad), defaultRail())
  const r = normalizeRail([{ type: "hashtag", tag: "a" }, { type: "hashtag", tag: "A" }, { type: "section", id: "wot" }, null, { type: "future", n: 1 }])
  assert.deepEqual(keys(r), ["section:feed", "hashtag:a", "section:wot", `future:${JSON.stringify({ type: "future", n: 1 })}`])
  // Unknown ones are kept, not drawn.
  assert.deepEqual(keys(shownFavs(r, FEED_IDS)), ["section:feed", "hashtag:a", "section:wot"])
  const many = Array.from({ length: 60 }, (_, i) => ({ type: "hashtag", tag: `t${i}` }))
  assert.equal(normalizeRail(many).length, MAX_FAVS + 1) // MAX_FAVS kept, then Feed put back on top
  assert.deepEqual(missingSections(r), ["search", "messages", "vault", "profile"])
})

test("pin, unpin (Feed stays), and no pin twice", () => {
  let r = defaultRail()
  r = pin(r, { type: "person", pubkey: A })
  assert.equal(r.at(-1).pubkey, A)
  assert.equal(pin(r, { type: "person", pubkey: A }), r)
  assert.equal(pin(r, { type: "person", pubkey: "nope" }), r)
  assert.ok(isPinned(r, { type: "person", pubkey: A }))
  assert.equal(unpin(r, "section:feed"), r)
  assert.ok(!isPinned(unpin(r, `person:${A}`), { type: "person", pubkey: A }))
  const full = Array.from({ length: MAX_FAVS }, (_, i) => ({ type: "hashtag", tag: `t${i}` }))
  assert.equal(pin(full, { type: "hashtag", tag: "more" }), full)
})

test("reorder: up/down among drawn ones, drag before another or to the end", () => {
  const r = normalizeRail([{ type: "section", id: "feed" }, { type: "future" }, { type: "hashtag", tag: "x" }, { type: "section", id: "wot" }])
  assert.deepEqual(keys(moveFav(r, "section:wot", -1, FEED_IDS)).filter(k => !k.startsWith("future")), ["section:feed", "section:wot", "hashtag:x"])
  assert.equal(moveFav(r, "section:feed", -1, FEED_IDS), r)
  assert.equal(moveFav(r, "section:wot", 1, FEED_IDS), r)
  assert.deepEqual(keys(moveFavBefore(r, "section:wot", "section:feed"))[0], "section:wot")
  assert.equal(keys(moveFavBefore(r, "section:feed", null)).at(-1), "section:feed")
  assert.equal(moveFavBefore(r, "hashtag:x", "section:wot"), r)
  assert.ok(sameRail(defaultRail(), defaultRail()))
  assert.ok(!sameRail(r, defaultRail()))
})

test("the Feed opens a pinned feed, relay or list from its address", () => {
  assert.deepEqual(linkChoice("#/feed?tag=Nostr"), { mode: "hashtag", tag: "nostr" })
  assert.deepEqual(linkChoice("#/feed?feed=global"), { mode: "global", tag: "" })
  assert.equal(linkChoice("#/feed?feed=made-up"), null)
  const relay = linkChoice("#/feed?relay=wss%3A%2F%2Frelay.damus.io%2F")
  assert.deepEqual(relay, { mode: "relay", tag: "", relay: "wss://relay.damus.io", label: "damus.io" })
  assert.equal(linkChoice("#/feed?relay=https%3A%2F%2Fx.com"), null)
  assert.deepEqual(linkChoice(`#/feed?list=${A}:friends`), { mode: "list", tag: "", list: `${A}:friends`, authors: null, label: "friends" })
  assert.equal(linkChoice("#/feed?list=nothex:friends"), null)
  assert.equal(linkChoice("#/feed"), null)
  assert.deepEqual(feedRelays(relay, ["wss://mine"]), ["wss://relay.damus.io"])
  assert.deepEqual(feedRelays({ mode: "global" }, ["wss://mine"]), ["wss://mine"])
  assert.notEqual(feedKey(relay), feedKey({ ...relay, relay: "wss://other" }))
  assert.notEqual(feedKey({ mode: "list", list: "x", authors: null }), feedKey({ mode: "list", list: "x", authors: [A] }))
})

test("a relay feed reads only that relay; a list feed only its people, newest page first", async () => {
  const asked = []
  const query = async (relays, f) => { asked.push({ relays, f }); return [{ id: `${relays[0]}-${f.authors?.[0] ?? "x"}`, kind: 1, created_at: asked.length, pubkey: f.authors?.[0] ?? A }] }
  const relay = { mode: "relay", relay: "wss://only.one" }
  const notes = await fetchStrangerFeed(relay, ["wss://mine"], { query })
  assert.deepEqual(asked[0].relays, ["wss://only.one"])
  assert.equal(notes.length, 1)
  assert.deepEqual(await fetchStrangerFeed({ mode: "list", list: "x", authors: null }, ["wss://mine"], { query }), [])
  asked.length = 0
  const people = Array.from({ length: 300 }, (_, i) => i.toString(16).padStart(64, "0"))
  const listed = await fetchStrangerFeed({ mode: "list", list: "x", authors: people }, ["wss://mine"], { query, limit: 1 })
  assert.equal(asked.length, 2, "300 people: two REQs of up to 250")
  assert.equal(listed.length, 1, "kept to one page")
  assert.equal(listed[0].created_at, 2, "the newest")
  assert.equal(liveFilters(relay).length, 1)
  assert.ok(liveKeeps({ mode: "list", authors: [A] }, { kind: 1, pubkey: A }))
  assert.ok(!liveKeeps({ mode: "list", authors: [A] }, { kind: 1, pubkey: B }))
})

const list = (pubkey, d, at, ps, extra = []) => ({ kind: 30000, pubkey, created_at: at, tags: [["d", d], ...extra, ...ps.map(p => ["p", p])] })
test("people lists: the newest copy of each, deleted or empty ones left out, named by title", async () => {
  const evs = [list(A, "f", 1, [A]), list(A, "f", 2, [A, B], [["title", "Friends"]]), list(A, "gone", 3, [B], [["deleted", "true"]]), list(A, "none", 3, []), { kind: 3, tags: [] }]
  const lists = newestLists(evs)
  assert.equal(lists.length, 1)
  assert.equal(listName(lists[0]), "Friends")
  assert.deepEqual(listPeople(lists[0]), [A, B])
  const ctx = { session: { pubkey: A }, account: { relays: { read: ["wss://r"], write: [] } }, vault: { outbox: { query: async () => [] } } }
  const query = async () => evs
  assert.deepEqual(await myLists(ctx, { query }), [{ pubkey: A, d: "f", name: "Friends", people: 2 }])
  const full = await resolveList(ctx, { mode: "list", list: `${A}:f`, authors: null }, { query })
  assert.deepEqual(full.authors, [A, B])
  assert.equal(full.label, "Friends")
  const missing = await resolveList(ctx, { mode: "list", list: `${A}:nope`, authors: null }, { query: async () => [] })
  assert.deepEqual(missing.authors, [])
})

test("the synced layout: one NIP-78 event sealed to yourself, the newest edit wins", async () => {
  assert.equal(SYNC_KIND, 30078)
  assert.deepEqual(SYNC_TAGS, [["d", SYNC_D], ["client", "Nostr Vault"], ["encryption", "nip44"]])
  const t = layoutTemplate("sealed", 7)
  assert.deepEqual(t, { kind: 30078, created_at: 7, tags: SYNC_TAGS, content: "sealed" })
  t.tags[0][1] = "changed"
  assert.equal(SYNC_TAGS[0][1], SYNC_D, "a template's tags are its own copy")
  const ev = (id, at, pubkey = A, d = SYNC_D) => ({ id, kind: 30078, pubkey, created_at: at, tags: [["d", d]], content: "" })
  assert.equal(newestEvent([ev("a", 1), ev("b", 3), ev("c", 9, B), ev("d", 9, A, "other")], A).id, "b")
  assert.ok(isLayoutEvent(ev("a", 1), A) && !isLayoutEvent(ev("a", 1), B))
  assert.equal(parseLayout("{nope"), null)
  assert.equal(parseLayout(JSON.stringify({ at: 1 })), null)
  const local = { ...defaultLayout(PANEL_IDS), at: 10 }
  assert.equal(newerLayout(local, { ...local, at: 9 }), local)
  assert.equal(newerLayout(local, null), local)
  assert.equal(newerLayout(local, { ...local, at: 11 }).at, 11)
})

test("push seals to your own key and publishes; pull opens the newest; read-only does neither", async () => {
  const sent = [], stored = []
  const crypto = { encrypt: async (pk, text) => `sealed-to-${pk}:${text}`, decrypt: async (pk, c) => c.replace(`sealed-to-${pk}:`, "") }
  const layout = { ...defaultLayout(PANEL_IDS), at: 42 }
  const ctx = {
    session: { pubkey: A }, signer: { crypto, signEvent: async t => ({ ...t, id: "e1", pubkey: A, sig: "s" }) },
    account: { relays: { write: [], read: [] } }, vault: { outbox: { event: async e => { stored.push(e) }, query: async () => stored } },
  }
  const pushed = await pushLayout(ctx, layout, { publish: async (c, t) => { sent.push(t); return { event: { ...t, id: "e1" } } } })
  assert.equal(sent.length, 1)
  assert.equal(sent[0].kind, 30078)
  assert.deepEqual(sent[0].tags, SYNC_TAGS)
  assert.equal(sent[0].content, `sealed-to-${A}:${JSON.stringify(layout)}`, "sealed to the account's own key")
  assert.equal(pushed.id, "e1")
  const readOnly = { ...ctx, signer: { readOnly: true } }
  assert.equal(await pushLayout(readOnly, layout, { publish: async () => { throw new Error("must not send") } }), null)
  assert.equal(await pullLayout({ ...ctx, signer: { readOnly: true } }), null)
  stored.push({ id: "e0", kind: 30078, pubkey: A, created_at: 5, tags: [["d", SYNC_D]], content: `sealed-to-${A}:${JSON.stringify(layout)}` })
  const back = await pullLayout(ctx, { query: async () => [] })
  assert.deepEqual(back, layout)
})

test("the desktop mounts the sync once and the rail and Your space share one layout", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("desktop/DesktopShell.jsx"), /useLayoutSync\(ctx\)/)
  assert.match(src("desktop/Sidebar.jsx"), /useLayout\(ctx\.session\.pubkey\)/)
  assert.match(src("desktop/space/SpaceDock.jsx"), /useLayout\(ctx\.session\.pubkey\)/)
  assert.match(src("desktop/space/layout-store.js"), /export const PUSH_DELAY_MS = 2000/)
  assert.match(src("desktop/space/layout-store.js"), /if \(ctx\.signer\?\.readOnly \|\| !ctx\.signer\?\.crypto\) return/)
})
