// The Feed's layouts (FeedLayoutMode, FeedView+Layout) and threads (FeedThreadGrouping), as on the iPhone: one
// setting per feed cycling Expanded -> Compact -> Threaded, and a newest-first feed grouped into conversations.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { buildThreads, latestReplies, repliesOf, nextLayout, loadLayout, saveLayout, hasLayouts, MAX_DEPTH } from "../src/net/feed-layout.js"

const id = n => String(n).padStart(64, "0")
const note = (n, at, parent, root) => ({
  id: id(n), kind: 1, pubkey: "a".repeat(64), created_at: at, content: `n${n}`,
  tags: parent ? (root && root !== parent ? [["e", id(root), "", "root"], ["e", id(parent), "", "reply"]] : [["e", id(parent), "", "root"]]) : [],
})
const ids = thread => thread.entries.map(e => [Number(e.note.id), e.depth])

test("the layout cycles Expanded -> Compact -> Threaded and back; only note feeds have layouts", () => {
  assert.equal(nextLayout("expanded"), "condensed")
  assert.equal(nextLayout("condensed"), "threaded")
  assert.equal(nextLayout("threaded"), "expanded")
  for (const m of ["following", "discovery", "global", "popular", "hashtag"]) assert.ok(hasLayouts(m), m)
  for (const m of ["media", "articles", "live"]) assert.ok(!hasLayouts(m), m)
})

test("each feed keeps its own layout; the defaults are the iPhone's (every timeline feed threaded)", () => {
  const store = new Map(), storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  for (const m of ["following", "discovery", "global", "popular", "hashtag"]) assert.equal(loadLayout(m, storage), "threaded", m)
  saveLayout("following", "expanded", storage)
  assert.equal(loadLayout("following", storage), "expanded")
  assert.equal(loadLayout("global", storage), "threaded")
  store.set("nv:feed-layouts", "not json")
  assert.equal(loadLayout("following", storage), "threaded")
})

test("replies gather under their root, depth first, oldest sibling first; threads sort by latest activity", () => {
  const feed = [note(5, 50, 2, 1), note(4, 40), note(3, 30, 1, 1), note(2, 20, 1, 1), note(1, 10)].sort((a, b) => b.created_at - a.created_at)
  const threads = buildThreads(feed)
  assert.deepEqual(threads.map(t => Number(t.rootId)), [1, 4], "the thread replied to at 50 rises above the note at 40")
  assert.deepEqual(ids(threads[0]), [[1, 0], [2, 1], [5, 2], [3, 1]])
  assert.equal(threads[0].latest, 50)
})

test("a root that never loaded: its replies still share one thread (NIP-10 root tag), with the root to fetch", () => {
  const threads = buildThreads([note(12, 20, 11, 10), note(13, 30, 10, 10)])
  assert.equal(threads.length, 1)
  assert.equal(threads[0].rootId, id(10))
  assert.equal(threads[0].root, null)
  const fetched = buildThreads([note(12, 20, 11, 10), note(13, 30, 10, 10)], { resolve: x => x === id(10) ? note(10, 5) : null })
  assert.equal(fetched[0].root.id, id(10))
  // As FeedThreadGrouping.flatten: the root's own replies, then those whose parent never loaded.
  assert.deepEqual(ids(fetched[0]), [[10, 0], [13, 1], [12, 1]])
})

test("Popular and Global keep the feed's order; Following sorts by activity", () => {
  const feed = [note(1, 10), note(2, 20), note(3, 30, 1, 1)]
  assert.deepEqual(buildThreads(feed, { keepFeedOrder: true }).map(t => Number(t.rootId)), [1, 2])
  assert.deepEqual(buildThreads(feed).map(t => Number(t.rootId)), [1, 2], "1 is newest by its reply at 30")
  assert.deepEqual(buildThreads([note(2, 20), note(1, 10)], { keepFeedOrder: true }).map(t => Number(t.rootId)), [2, 1])
})

test("indentation stops at the iPhone's depth; a reply loop is drawn once", () => {
  const chain = [note(1, 1)]
  for (let i = 2; i <= 8; i++) chain.push(note(i, i, i - 1, 1))
  const [t] = buildThreads(chain)
  assert.equal(Math.max(...t.entries.map(e => e.depth)), MAX_DEPTH)
  assert.equal(t.entries.length, 8)
  const a = { ...note(20, 1), tags: [["e", id(21), "", "reply"]] }, b = { ...note(21, 2), tags: [["e", id(20), "", "reply"]] }
  const loop = buildThreads([a, b])
  assert.equal(loop.flatMap(x => x.entries).length, 2)
})

test("a folded card shows the newest replies, in reading order", () => {
  const feed = [note(1, 1), note(2, 50, 1, 1), note(3, 10, 1, 1), note(4, 40, 1, 1), note(5, 20, 1, 1)]
  const [t] = buildThreads(feed)
  assert.equal(repliesOf(t).length, 4)
  assert.deepEqual(latestReplies(t, 3).map(e => Number(e.note.id)), [5, 4, 2])
})

test("a repost is its own row, not a reply", () => {
  const repost = { id: id(30), kind: 6, pubkey: "b".repeat(64), created_at: 5, content: "", tags: [["e", id(1)]] }
  const threads = buildThreads([repost, note(1, 1)])
  assert.deepEqual(threads.map(t => Number(t.rootId)).sort(), [1, 30])
})

test("the layout components load", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  const { plainText } = await import("../src/components/CondensedNote.jsx")
  assert.equal(plainText("look https://x.example/a.jpg at\n\nthis nostr:npub1abc"), "look at this @…")
  // A line names its @mentions, chips its links and marks quotes and Nostr Vault notes, as CondensedNoteLine does.
  const { textParts, linkUrls, domainOf, quotes, fromNostrVault } = await import("../src/components/CondensedNote.jsx")
  const npub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
  const parts = textParts(`hi nostr:${npub} see https://www.example.com/x and nostr:note1abc`)
  assert.equal(parts[0], "hi ")
  assert.match(parts[1].pubkey, /^[0-9a-f]{64}$/)
  assert.equal(parts.at(-1), " see and")
  assert.deepEqual(linkUrls({ content: "a https://x.example/p.jpg b https://www.example.com/x, c https://www.example.com/x" }), ["https://www.example.com/x"])
  assert.equal(domainOf("https://www.example.com/x"), "example.com")
  assert.equal(quotes({ content: "nostr:nevent1qq", tags: [] }), true)
  assert.equal(quotes({ content: "plain", tags: [["q", "ab"]] }), true)
  assert.equal(quotes({ content: "plain", tags: [] }), false)
  assert.equal(fromNostrVault({ tags: [["client", "Nostr Vault on iOS"]] }), true)
  assert.equal(fromNostrVault({ tags: [["client", "Damus"]] }), false)
  assert.equal(typeof (await import("../src/components/FeedRows.jsx")).FeedRows, "function")
  assert.equal(typeof (await import("../src/screens/FeedScreen.jsx")).FeedScreen, "function")
})

test("Replies and Reposts switches, and the notes the New Posts pill holds", async () => {
  const { applyFilters, loadFilters, saveFilters, newerNotes, FILTER_DEFAULTS } = await import("../src/net/feed-filters.js")
  const note = { id: "a", kind: 1, created_at: 10, tags: [] }
  const reply = { id: "b", kind: 1, created_at: 11, tags: [["e", "a".repeat(64), "", "reply"]] }
  const repost = { id: "c", kind: 6, created_at: 12, tags: [] }
  const all = [note, reply, repost]
  assert.deepEqual(applyFilters(all, FILTER_DEFAULTS).map(n => n.id), ["a", "b", "c"])
  assert.deepEqual(applyFilters(all, { replies: false, reposts: false }).map(n => n.id), ["a"])
  assert.deepEqual(applyFilters(all, { replies: false, reposts: true }, { threaded: true }).map(n => n.id), ["a", "b", "c"])
  const mem = new Map(), storage = { getItem: k => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) }
  assert.deepEqual(loadFilters(storage), FILTER_DEFAULTS)
  saveFilters({ ...FILTER_DEFAULTS, reposts: false }, storage)
  assert.equal(loadFilters(storage).reposts, false)
  assert.deepEqual(newerNotes([note, reply], [{ id: "d", created_at: 20 }, reply, { id: "e", created_at: 5 }, { id: "f", created_at: 30 }]).map(n => n.id), ["f", "d"])
})

test("a reply to someone you blocked is hidden with them; a bare repost of them too (FeedFilterEngine)", async () => {
  const { visibleNotes } = await import("../src/net/blocks.js")
  const bad = "b".repeat(64), ok = "c".repeat(64)
  const theirs = { id: "1".repeat(64), kind: 1, pubkey: bad, created_at: 1, tags: [] }
  const reply = { id: "2".repeat(64), kind: 1, pubkey: ok, created_at: 2, tags: [["e", theirs.id, "", "reply"]] }
  const bare = { id: "3".repeat(64), kind: 6, pubkey: ok, created_at: 3, content: "", tags: [["e", "9".repeat(64)], ["p", bad]] }
  const mine = { id: "4".repeat(64), kind: 1, pubkey: ok, created_at: 4, tags: [] }
  assert.deepEqual(visibleNotes([theirs, reply, bare, mine], new Set([bad])).map(n => n.id), [mine.id])
  assert.equal(visibleNotes([theirs, reply, bare, mine], new Set()).length, 4)
})

test("a repost line opens the note it carries only if that note's signature checks", async () => {
  const { finalizeEvent, generateSecretKey } = await import("nostr-tools/pure")
  const { shownId } = await import("../src/components/FeedThreadCard.jsx")
  const real = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "hi" }, generateSecretKey())
  const repost = inner => ({ id: "r".repeat(64), kind: 6, pubkey: "b".repeat(64), created_at: 2, content: JSON.stringify(inner), tags: [["e", real.id]] })
  assert.equal(shownId(repost(real)), real.id)
  assert.equal(shownId(repost({ ...real, id: "9".repeat(64) })), "r".repeat(64), "a forged inner id can't aim Open thread elsewhere")
  assert.equal(shownId({ ...repost(real), content: "" }), "r".repeat(64))
  assert.equal(shownId(real), real.id)
})
