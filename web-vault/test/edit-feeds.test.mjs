// Edit Feeds (components/EditFeeds.jsx, net/feeds.js): the picker's order and hidden feeds, as the iPhone's
// FeedMenuOrder (Models/FeedLayoutMode.swift) and its FeedLayoutModeTests.
import test from "node:test"
import assert from "node:assert/strict"
import { FEEDS, menuOrder, loadMenu, saveMenu, menuFeeds, visibleFeeds, moveItem, loadChoice } from "../src/net/feeds.js"

const memStorage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), m } }
const ids = list => list.map(f => f.id)

test("a saved order keeps its order, drops feeds no longer offered and duplicates", () => {
  assert.deepEqual(menuOrder(["media", "global", "gone", "media", "following", "discovery", "hashtag", "popular"], ids(FEEDS)),
    ["media", "global", "following", "discovery", "hashtag", "popular"])
})

test("a feed the saved order doesn't know goes in after its default neighbour, or first", () => {
  const defaults = ["following", "global", "hashtag", "popular", "media", "articles"]
  assert.deepEqual(menuOrder(["media", "following", "global", "hashtag", "popular"], defaults),
    ["media", "articles", "following", "global", "hashtag", "popular"])
  assert.deepEqual(menuOrder(["global", "hashtag"], ["following", "global", "hashtag"]), ["following", "global", "hashtag"])
  assert.deepEqual(menuOrder([], ids(FEEDS)), ids(FEEDS))
})

test("nothing saved, or junk, means the default order with nothing hidden", () => {
  const s = memStorage()
  assert.deepEqual(loadMenu(s), { order: [], hidden: [] })
  s.setItem("nv-feed-menu", "{not json")
  assert.deepEqual(loadMenu(s), { order: [], hidden: [] })
  s.setItem("nv-feed-menu", JSON.stringify({ order: "media", hidden: [3, "popular"] }))
  assert.deepEqual(loadMenu(s), { order: [], hidden: ["popular"] })
  assert.deepEqual(ids(visibleFeeds(FEEDS, loadMenu(memStorage()))), ids(FEEDS))
})

test("hiding and reordering is saved and shapes the picker; Following can't be hidden", () => {
  const s = memStorage()
  const order = moveItem(ids(FEEDS), 5, 0) // Media to the top
  saveMenu({ order, hidden: ["popular", "following"] }, FEEDS, s)
  const menu = loadMenu(s)
  assert.deepEqual(menu, { order: ["media", "following", "discovery", "global", "hashtag", "popular"], hidden: ["popular"] })
  assert.deepEqual(ids(visibleFeeds(FEEDS, menu)), ["media", "following", "discovery", "global", "hashtag"])
  assert.deepEqual(menuFeeds(FEEDS, { order: [], hidden: ["following"] })[0], { id: "following", label: "Following", shown: true })
  assert.equal(visibleFeeds(FEEDS, menu)[0].shown, undefined)
})

test("Reset to Default saves nothing, so feeds added later keep their default place", () => {
  const s = memStorage()
  saveMenu({ order: ["global", "following"], hidden: ["media"] }, FEEDS, s)
  assert.ok(s.m.has("nv-feed-menu"))
  saveMenu({ order: [], hidden: [] }, FEEDS, s)
  assert.equal(s.m.has("nv-feed-menu"), false)
  saveMenu({ order: ids(FEEDS), hidden: ["global"] }, FEEDS, s)
  assert.deepEqual(JSON.parse(s.getItem("nv-feed-menu")), { order: [], hidden: ["global"] })
})

test("a saved feed that has been hidden opens Following", () => {
  const s = memStorage()
  s.setItem("nv-feed", JSON.stringify({ mode: "popular" }))
  assert.equal(loadChoice(s, visibleFeeds(FEEDS, { order: [], hidden: ["popular"] })).mode, "following")
  assert.equal(loadChoice(s, visibleFeeds(FEEDS, { order: [], hidden: [] })).mode, "popular")
})

test("Discover, new in this version, joins a saved order after Following", () => {
  const saved = { order: ["media", "following", "global", "hashtag", "popular"], hidden: [] }
  assert.deepEqual(ids(visibleFeeds(FEEDS, saved)), ["media", "following", "discovery", "global", "hashtag", "popular"])
})

test("moveItem moves one item up or down", () => {
  assert.deepEqual(moveItem(["a", "b", "c"], 2, 0), ["c", "a", "b"])
  assert.deepEqual(moveItem(["a", "b", "c"], 0, 1), ["b", "a", "c"])
})
