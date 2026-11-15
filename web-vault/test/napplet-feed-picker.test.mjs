// The Reader napplet's feed picker: Following, Global, Media, Articles, Polls (and a hashtag). Each feed's filters
// mirror the classic one's; every read still passes the shell's web gate.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents } from "../src/napplet/reader-intents.js"
import { TRUSTED_AUTHORS_CAP } from "../src/readers/trust.js"

const html = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
const block = html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))
const R = {}
vm.runInNewContext(`${block}\n;Object.assign(box, { feedFilters, feedKeeps, FEED_MODES, FEED_KINDS, TRUSTED_CAP })`, { box: R, Date, URL, Intl })
const plain = x => JSON.parse(JSON.stringify(x))
const H = c => c.repeat(64)

test("feedFilters: Following/Media ask you + your follows; Global/Articles/Polls ask your web by name, then open", () => {
  assert.deepEqual(plain(R.feedFilters("following", { me: H("a"), follows: [H("b"), H("a")], limit: 40 })), [{ kinds: [...R.FEED_KINDS], authors: [H("a"), H("b")], limit: 40 }])
  assert.deepEqual(plain(R.feedFilters("media", { me: H("a"), follows: [], until: 99 })), [{ kinds: [...R.FEED_KINDS], authors: [H("a")], limit: 40, until: 99 }])
  const web = Array.from({ length: 600 }, (_, i) => i.toString(16).padStart(64, "0"))
  const g = plain(R.feedFilters("global", { me: H("a"), web }))
  assert.equal(g.length, 2)
  assert.equal(g[0].authors.length, 500)
  assert.equal(R.TRUSTED_CAP, TRUSTED_AUTHORS_CAP, "the classic Global's cap")
  assert.deepEqual(g[1], { kinds: [...R.FEED_KINDS], limit: 40 })
  assert.deepEqual(plain(R.feedFilters("articles", { web: [H("c")] }))[0].kinds, [30023])
  assert.deepEqual(plain(R.feedFilters("polls", { web: [H("c")] }))[1], { kinds: [1068], limit: 40 })
  assert.deepEqual(plain(R.feedFilters("global", { me: H("a"), web: [] })), [], "no web yet: nothing to ask")
  assert.deepEqual(plain(R.feedFilters("following", {})), [])
})

test("feedKeeps: Global leaves replies out; Media keeps pictures/video (a repost's too); Articles/Polls their kind", () => {
  const note = (content, tags = []) => ({ id: H("1"), pubkey: H("a"), kind: 1, created_at: 1, content, tags })
  const reply = note("re", [["e", H("9"), "", "root"]])
  assert.equal(R.feedKeeps("global", note("hi")), true)
  assert.equal(R.feedKeeps("global", reply), false)
  assert.equal(R.feedKeeps("following", reply), true)
  assert.equal(R.feedKeeps("media", note("look https://p.example/a.jpg")), true)
  assert.equal(R.feedKeeps("media", note("look", [["imeta", "url https://p.example/x", "m image/png"]])), true)
  assert.equal(R.feedKeeps("media", note("text only")), false)
  const inner = { ...note("https://v.example/v.mp4"), id: H("2"), sig: "s" }
  assert.equal(R.feedKeeps("media", { id: H("3"), pubkey: H("b"), kind: 6, created_at: 2, content: JSON.stringify(inner), tags: [] }), true)
  assert.equal(R.feedKeeps("articles", { kind: 30023, content: "", tags: [] }), true)
  assert.equal(R.feedKeeps("polls", note("Q?")), false)
  assert.deepEqual(plain(R.FEED_MODES).map(m => m[0]), ["following", "global", "media", "articles", "polls"])
})

test("web/people: Reader only; pubkeys only, at most 500", async () => {
  const bus = createBus()
  const many = [...Array.from({ length: 520 }, (_, i) => i.toString(16).padStart(64, "0")), "junk"]
  readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, webPeople: async () => many })
  const r = await bus.invoke({ dTag: "nv-reader", send: () => {} }, { archetype: "web", action: "people", payload: {} })
  assert.equal(r.data.people.length, 500)
  assert.ok(r.data.people.every(pk => /^[0-9a-f]{64}$/.test(pk)))
  assert.equal((await bus.invoke({ dTag: "nv-messages", send: () => {} }, { archetype: "web", action: "people", payload: {} })).ok, false)
})
