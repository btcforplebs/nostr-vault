// The left rail's pins (src/desktop/rail/rail-favs.js) in docs/SPACE_LAYOUT.md's format, the Feed links they open
// (net/feeds.js linkChoice), list feeds (net/list-feed.js) and the layout's vault sync (net/space-sync.js,
// desktop/space/layout-store.js). The pin cases are the iPad's SpaceLayoutTests ones.
import test from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { defaultPins, favourite, isPinned, MAX_FAVOURITES, movePin, movePinBefore, normalizePins, normalizeRelay, normalizeValue, pin, pinHref, pinKey, RAIL_SECTIONS, relayName, samePins, SECTION_IDS, shownPins, unpin } from "../src/desktop/rail/rail-favs.js"
import { linkChoice, feedRelays, feedKey, fetchStrangerFeed, liveFilters, liveKeeps } from "../src/net/feeds.js"
import { listAddress, listName, listPeople, myLists, newestLists, resolveList } from "../src/net/list-feed.js"
import { SYNC_D, defaultLayout, normalize } from "../src/desktop/space/space-layout.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"
import { changeLayout, currentLayout } from "../src/desktop/space/layout-store.js"
import { setOpen, setPins } from "../src/desktop/space/space-layout.js"

const A = "a".repeat(64), B = "b".repeat(64)
const keys = r => r.map(pinKey)
const sections = r => r.filter(p => p.type === "section").map(p => p.id)

test("the default pins are every section in the doc's order; the web's rail draws seven of them (Notifications has its own row, parity #31)", () => {
  assert.deepEqual(SECTION_IDS, ["feed", "search", "profile", "wot", "vault", "messages", "notifications", "relay", "settings"])
  assert.deepEqual(defaultPins(), SECTION_IDS.map(id => ({ type: "section", id })))
  assert.deepEqual(RAIL_SECTIONS, ["feed", "search", "profile", "wot", "vault", "messages", "notifications"])
  assert.deepEqual(shownPins(defaultPins()).map(p => p.id), RAIL_SECTIONS)
})

test("pin values are normalised per the doc's table, or refused", () => {
  assert.equal(normalizeValue("person", A.toUpperCase()), A)
  assert.equal(normalizeValue("person", "xyz"), "")
  assert.equal(normalizeValue("hashtag", "##Bitcoin"), "bitcoin")
  assert.equal(normalizeValue("hashtag", "two words"), "")
  assert.equal(normalizeValue("list", `30000:${A.toUpperCase()}:Devs`), `30000:${A}:Devs`)
  assert.equal(normalizeValue("list", `39089:${A}:pack`), `39089:${A}:pack`)
  assert.equal(normalizeValue("list", `3:${A}:x`), "")
  assert.equal(normalizeValue("list", `30000:${A}:`), "")
  assert.equal(normalizeValue("relay", " WSS://Relay.Example.COM/ "), "wss://relay.example.com")
  assert.equal(normalizeRelay("https://x.com"), "")
  assert.equal(normalizeRelay("ws://127.0.0.1:4869"), "ws://127.0.0.1:4869")
  assert.equal(relayName("wss://relay.damus.io"), "damus.io")
  assert.equal(relayName("wss://nos.lol"), "nos.lol")
  assert.deepEqual(favourite("person", A, " Ann "), { type: "person", p: A, name: "Ann" })
  assert.equal(favourite("section", "feed"), null)
  assert.equal(favourite("hashtag", "a b"), null)
})

test("normalizePins: bad entries and repeats drop out, unknown types and sections and fields stay as read", () => {
  const future = { type: "zaps-board", x: 1 }
  const r = normalizePins([
    { type: "hashtag", t: "#A" }, { type: "hashtag", t: "a" }, null, [], { t: "x" }, { type: "person", p: "bad" },
    { type: "section", id: "wot", w: 2 }, future, { type: "section", id: "studio" }, { type: "relay", url: "wss://R.io/", name: "R" },
  ])
  assert.deepEqual(r.filter(p => p.type === "hashtag"), [{ type: "hashtag", t: "a" }], "the first, normalised; the repeat dropped")
  assert.ok(r.some(p => p.type === "section" && p.id === "wot" && p.w === 2), "an extra field kept")
  assert.ok(r.includes(future), "a newer type kept exactly as read")
  assert.ok(r.some(p => p.type === "section" && p.id === "studio"), "a section this app lacks kept")
  assert.deepEqual(r.find(p => p.type === "relay"), { type: "relay", url: "wss://r.io", name: "R" })
  assert.ok(!shownPins(r).includes(future) && !shownPins(r).some(p => p.id === "studio"), "...and not drawn")
})

test("sections can move, not go: a missing one comes back after the section before it", () => {
  const r = normalizePins([{ type: "section", id: "vault" }, { type: "hashtag", t: "x" }, { type: "section", id: "feed" }])
  assert.equal(sections(r).length, 9, "every section is there")
  // messages and the ones after it follow vault (the section before them that is there); search, profile and wot
  // follow feed, the one before them.
  assert.deepEqual(keys(r), ["section:vault", "section:messages", "section:notifications", "section:relay", "section:settings",
    "hashtag:x", "section:feed", "section:search", "section:profile", "section:wot"])
  assert.equal(unpin(r, "section:vault"), r, "a section is never taken off")
})

test("favourites past the 30th drop out; pin refuses a 31st, a repeat and a section", () => {
  const many = Array.from({ length: 40 }, (_, i) => ({ type: "hashtag", t: `t${i}` }))
  const r = normalizePins(many)
  assert.equal(r.filter(p => p.type === "hashtag").length, MAX_FAVOURITES)
  assert.equal(pin(r, favourite("hashtag", "more")), r)
  let d = defaultPins()
  d = pin(d, favourite("person", A))
  assert.equal(d.at(-1).p, A)
  assert.equal(pin(d, favourite("person", A)), d)
  assert.equal(pin(d, { type: "section", id: "feed" }), d)
  assert.ok(isPinned(d, favourite("person", A)))
  assert.ok(!isPinned(unpin(d, `person:${A}`), favourite("person", A)))
})

test("each pin opens its place", () => {
  assert.equal(pinHref({ type: "section", id: "wot" }), "#/wot")
  assert.equal(pinHref({ type: "section", id: "settings" }), null, "Settings is the rail's foot, not a row")
  assert.equal(pinHref({ type: "person", p: A }), `#/profile/${A}`)
  assert.equal(pinHref({ type: "hashtag", t: "nostr" }), "#/feed?tag=nostr")
  assert.equal(pinHref({ type: "list", a: `30000:${A}:a b` }), `#/feed?list=30000%3A${A}%3Aa%20b`)
  assert.equal(pinHref({ type: "relay", url: "wss://nos.lol" }), "#/feed?relay=wss%3A%2F%2Fnos.lol")
  assert.equal(pinHref({ type: "zaps-board" }), null)
})

test("reorder: up/down among drawn ones (hidden ones keep their places), drag before another or to the end", () => {
  const r = normalizePins([{ type: "section", id: "feed" }, { type: "future" }, { type: "hashtag", t: "x" }])
  const drawn = p => shownPins(p).map(pinKey)
  // x steps over the future pin (not drawn) and the sections not drawn, and swaps with Notifications.
  assert.deepEqual(drawn(movePin(r, "hashtag:x", -1)).slice(-2), ["hashtag:x", "section:notifications"])
  assert.equal(keys(movePin(r, "hashtag:x", -1)).indexOf(`future:{"type":"future"}`), keys(r).indexOf(`future:{"type":"future"}`), "the future pin keeps its place")
  assert.equal(movePin(r, "section:feed", -1), r)
  assert.equal(keys(movePinBefore(r, "section:feed", null)).at(-1), "section:feed")
  assert.equal(movePinBefore(r, "hashtag:x", "hashtag:x"), r)
  assert.ok(samePins(defaultPins(), defaultPins()))
  assert.ok(!samePins(r, defaultPins()))
})

test("the Feed opens a pinned relay or list from its address", () => {
  assert.deepEqual(linkChoice("#/feed?tag=Nostr"), { mode: "hashtag", tag: "nostr" })
  assert.deepEqual(linkChoice("#/feed?feed=global"), { mode: "global", tag: "" })
  assert.equal(linkChoice("#/feed?feed=made-up"), null)
  const relay = linkChoice("#/feed?relay=wss%3A%2F%2Frelay.damus.io%2F")
  assert.deepEqual(relay, { mode: "relay", tag: "", relay: "wss://relay.damus.io", label: "damus.io" })
  assert.equal(linkChoice("#/feed?relay=https%3A%2F%2Fx.com"), null)
  assert.deepEqual(linkChoice(`#/feed?list=${encodeURIComponent(`30000:${A}:friends`)}`), { mode: "list", tag: "", list: `30000:${A}:friends`, authors: null, label: "friends" })
  assert.equal(linkChoice(`#/feed?list=${A}:friends`), null, "an address needs its kind")
  assert.equal(linkChoice(`#/feed?list=1:${A}:friends`), null)
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
  // Read through your web of trust, like Global (Logen 2026-11-04): with no web nothing is asked.
  assert.deepEqual(await fetchStrangerFeed(relay, ["wss://mine"], { query }), [])
  assert.equal(asked.length, 0)
  const notes = await fetchStrangerFeed(relay, ["wss://mine"], { query, trust: new Set([A]) })
  assert.deepEqual(asked.map(a => a.relays), [["wss://only.one"], ["wss://only.one"]], "the web's authors, then open, that relay only")
  assert.equal(notes.length, 2)
  assert.deepEqual(await fetchStrangerFeed({ mode: "list", list: "x", authors: null }, ["wss://mine"], { query }), [])
  asked.length = 0
  const people = Array.from({ length: 300 }, (_, i) => i.toString(16).padStart(64, "0"))
  const listed = await fetchStrangerFeed({ mode: "list", list: "x", authors: people }, ["wss://mine"], { query, limit: 1 })
  assert.equal(asked.length, 2, "300 people: two REQs of up to 250")
  assert.equal(listed.length, 1, "kept to one page")
  assert.equal(listed[0].created_at, 2, "the newest")
  assert.equal(liveFilters(relay).length, 0, "no web: nothing kept open")
  assert.equal(liveFilters(relay, { trust: new Set([A]) }).length, 2, "the web's authors, then open")
  assert.ok(liveKeeps(relay, { kind: 1, pubkey: A }, { trust: new Set([A]) }))
  assert.ok(!liveKeeps(relay, { kind: 1, pubkey: B }, { trust: new Set([A]) }), "a stranger's")
  assert.ok(liveKeeps({ mode: "list", authors: [A] }, { kind: 1, pubkey: A }))
  assert.ok(!liveKeeps({ mode: "list", authors: [A] }, { kind: 1, pubkey: B }))
})

const list = (pubkey, d, at, ps, extra = [], kind = 30000) => ({ kind, pubkey, created_at: at, tags: [["d", d], ...extra, ...ps.map(p => ["p", p])] })
test("people lists and follow packs: the newest copy of each by address, deleted or empty ones left out", async () => {
  const evs = [list(A, "f", 1, [A]), list(A, "f", 2, [A, B], [["title", "Friends"]]), list(A, "f", 3, [B], [], 39089),
    list(A, "gone", 3, [B], [["deleted", "true"]]), list(A, "none", 3, []), { kind: 3, tags: [] }]
  const lists = newestLists(evs)
  assert.deepEqual(lists.map(listAddress).sort(), [`30000:${A}:f`, `39089:${A}:f`])
  const friends = lists.find(e => e.kind === 30000)
  assert.equal(listName(friends), "Friends")
  assert.deepEqual(listPeople(friends), [A, B])
  const ctx = { session: { pubkey: A }, account: { relays: { read: ["wss://r"], write: [] } }, vault: { outbox: { query: async () => [] } } }
  const query = async () => evs
  assert.deepEqual(await myLists(ctx, { query }), [{ a: `39089:${A}:f`, name: "f", people: 1 }, { a: `30000:${A}:f`, name: "Friends", people: 2 }])
  const asked = []
  const full = await resolveList(ctx, { mode: "list", list: `39089:${A}:f`, authors: null }, { query: async (r, f) => { asked.push(f); return evs } })
  assert.deepEqual(asked[0].kinds, [39089])
  assert.deepEqual(full.authors, [B])
  const missing = await resolveList(ctx, { mode: "list", list: `30000:${A}:nope`, authors: null }, { query: async () => [] })
  assert.deepEqual(missing.authors, [])
})


// A stand-in NIP-44: base64 of the text, so it is neither the plaintext nor JSON.
const b64 = s => Buffer.from(s).toString("base64")
const crypto = { encrypt: async (pk, text) => `${pk.slice(0, 4)}${b64(text)}`, decrypt: async (pk, c) => Buffer.from(c.slice(4), "base64").toString() }








test("normalize is the doc's: what the iPad wrote survives a web round trip", () => {
  const ipad = { v: 1, at: 1793736000, pins: [
    { type: "section", id: "feed" }, { type: "list", a: `30000:${A}:Devs`, name: "Devs" }, { type: "person", p: B },
    { type: "section", id: "search" }, { type: "hashtag", t: "bitcoin" }, { type: "relay", url: "wss://relay.example.com" },
  ], panels: [{ id: "live-vault", on: true, open: true }], deviceNote: "x" }
  const back = JSON.parse(JSON.stringify(normalize(ipad, PANEL_IDS)))
  // Every pin the iPad wrote, in its order (the sections it left out go back in between, per the doc).
  const wrote = new Set(ipad.pins.map(pinKey))
  assert.deepEqual(back.pins.filter(p => wrote.has(pinKey(p))), ipad.pins)
  assert.equal(back.deviceNote, "x")
  assert.equal(back.at, ipad.at)
})

test("the layout is this browser's only: no NIP-78 (kind 30078) publish, pull, refocus read or retry (Logen 2026-11-05)", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("desktop/Sidebar.jsx"), /useLayout\(ctx\.session\.pubkey\)/)
  assert.match(src("desktop/space/SpaceDock.jsx"), /useLayout\(ctx\.session\.pubkey\)/)
  // The code, not the comments (which say what was removed).
  const store = src("desktop/space/layout-store.js").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "")
  for (const gone of [/space-sync/, /startSync/, /useLayoutSync/, /pullLayout|pushLayout/, /visibilitychange/, /setTimeout/, /30078/]) assert.doesNotMatch(store, gone)
  assert.doesNotMatch(src("desktop/DesktopShell.jsx"), /useLayoutSync|space-sync/)
  assert.ok(!existsSync(new URL("../src/net/space-sync.js", import.meta.url)), "the NIP-78 sync file is gone")
})

test("an edit is kept in this browser at once and read back; nothing is signed or sent", async () => {
  const m = new Map()
  globalThis.localStorage = { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
  const { pool } = await import("../src/net/pool.js")
  let sent = 0
  const publish = pool.publish
  pool.publish = () => { sent++; return [] }
  try {
    const me = "c".repeat(64)
    const before = currentLayout(me)
    changeLayout(me, l => ({ ...l, at: (l.at ?? 0) + 1, panels: l.panels.map((p, i) => (i === 0 ? { ...p, on: !p.on } : p)) }))
    await new Promise(r => setTimeout(r, 30))
    const after = currentLayout(me)
    assert.notEqual(after.panels[0].on, before.panels[0].on)
    assert.equal(sent, 0)
    assert.ok([...m.keys()].some(k => k.endsWith(`:${me}`)), "saved under the account (sign-out forgets it)")
  } finally { pool.publish = publish }
})
