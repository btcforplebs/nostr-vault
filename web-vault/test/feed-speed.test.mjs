// Feed speed fixes (RESEARCH/NV_FEED_TAB_PERF_REVIEW_2026_11_27.md 2, 5, 7): memo cards so a live note or a wider
// draw window redraws only what changed, a live batch goes in without reading Haven again, and Popular asks two
// relays for the whole network's engagement and, ranked again, only what came after the last ask.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { registerHooks } from "node:module"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { trustedTally, GLOBAL_RELAYS, TALLY_SLACK_S } from "../src/net/popular.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { sameThread, openIn, FeedThreadCardMemo } = await import("../src/components/FeedThreadCard.jsx")

const read = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const hex = n => n.toString(16).padStart(64, "0")

test("#5: the whole network's engagement from two relays, the follows' from all; ranked again, only what is newer", async () => {
  const relays = ["wss://a", "wss://b", "wss://c", "wss://d", "wss://e"]
  const asks = []
  const old = { id: hex(1), kind: 7, pubkey: hex(9), created_at: 1000, tags: [] }
  const fresh = { id: hex(2), kind: 7, pubkey: hex(9), created_at: 90_500, tags: [] }
  let answer = [old]
  const query = async (urls, f) => { asks.push({ urls, f }); return f.authors ? [] : (f.kinds?.includes(3) ? [] : answer) }
  const kept = new Map(), now = 87_000
  await trustedTally({ me: hex(5), follows: [hex(6)], relays, now, window: 86_400, trust: async e => e, query, kept })
  const global = asks.find(a => a.f.limit === 5000), mine = asks.find(a => a.f.authors?.includes(hex(6)) && a.f.kinds?.includes(7))
  assert.deepEqual(global.urls, relays.slice(0, GLOBAL_RELAYS))
  assert.deepEqual(mine.urls, relays)
  assert.equal(global.f.since, now - 86_400)
  asks.length = 0
  answer = [fresh]
  const later = 91_000
  await trustedTally({ me: hex(5), follows: [hex(6)], relays, now: later, window: 86_400, trust: async e => e, query, kept })
  assert.equal(asks.find(a => a.f.limit === 5000).f.since, now - TALLY_SLACK_S, "only from just before the last ask")
  const held = [...kept.values()][0].byId
  assert.ok(held.has(fresh.id), "the new answer joins what is held")
  assert.ok(!held.has(old.id), "what fell out of the window is dropped")
})

test("#2/#7: a thread card is the same while its root and lines are; it draws when one is added or the open line is its own", () => {
  const n = id => ({ id: hex(id), kind: 1, pubkey: hex(9), created_at: id, tags: [] })
  const t = { rootId: hex(1), root: n(1), entries: [{ note: n(1), depth: 0 }, { note: n(2), depth: 1 }] }
  assert.equal(sameThread(t, { ...t, entries: t.entries.map(e => ({ ...e, note: { ...e.note } })) }), true, "rebuilt, same shape")
  assert.equal(sameThread(t, { ...t, entries: [...t.entries, { note: n(3), depth: 1 }] }), false)
  assert.equal(sameThread(t, { ...t, root: null }), false, "the root arrived or left")
  assert.equal(openIn(t, hex(2)), hex(2))
  assert.equal(openIn(t, hex(7)), null, "another card's open line doesn't touch this one")
  const c = new FeedThreadCardMemo({})
  c.props = { thread: t, openId: null, setOpenId: () => {}, memoryOnly: false }
  assert.equal(c.shouldComponentUpdate({ thread: { ...t }, openId: null, setOpenId: () => {}, memoryOnly: false }), false, "a new setOpenId isn't a change")
  assert.equal(c.shouldComponentUpdate({ thread: t, openId: hex(2), setOpenId: () => {}, memoryOnly: false }), true)
})

test("#2/#7: the Feed draws memo cards, and a live batch goes in without reading Haven's page again", () => {
  const rows = read("components/FeedRows.jsx"), feed = read("screens/FeedScreen.jsx")
  assert.match(rows, /<FeedThreadCardMemo thread=\{t\} openId=\{openIn\(t, openId\)\}/)
  assert.match(rows, /<NoteCardMemo event=\{n\}/)
  assert.match(feed, /const read = batch\.length \? \[\] : await readFeed\(vault, follows, \{ limit: PAGE \}\)/)
})
