// The profile page's speed fixes (RESEARCH/NV_PROFILE_PERF_REVIEW_2026_11_27.md 2, 3, 4, 6, 8): your own profile
// asks only for what is newer once it has asked for the whole page; names asked by many cards go out as one ask;
// cards don't redraw for a list that didn't change them; new notes arrive live; zap totals go out as one REQ a relay.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { wantProfile, BATCH_MS } from "../src/net/profile-batch.js"
import { queryMany } from "../src/net/query-many.js"
import { ownSince, markOwnAsked, forgetOwnAsked, watchProfile } from "../src/net/profile-live.js"
import { memoCard } from "../src/components/memo-card.js"
import { lookInFront } from "../src/components/auto-look.js"
import { fetchTagged, syncOwnPage, SINCE_SLACK_S } from "../src/net/person.js"
import { syncOwn } from "../src/net/sync.js"

const read = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const key = i => i.toString(16).padStart(64, "0")
const wait = ms => new Promise(r => setTimeout(r, ms))

test("#3: names asked within a moment go out as one fetchProfiles per save mode; saved wins over memory-only", async () => {
  const calls = []
  const fetch = async (vault, pks, relays, o) => { calls.push({ pks, relays, save: o.save }) }
  const src = () => ({ vault: "V", relays: ["wss://r"] })
  for (let i = 1; i <= 30; i++) wantProfile(key(i), src, { fetch, save: i % 2 === 0, delayMs: 5 })
  wantProfile(key(1), src, { fetch, save: true, delayMs: 5 })
  await wait(30)
  assert.equal(calls.length, 2)
  const saved = calls.find(c => c.save), memory = calls.find(c => !c.save)
  assert.equal(saved.pks.length, 16, "15 even + key(1) asked saved too")
  assert.equal(memory.pks.length, 14)
  assert.ok(!memory.pks.includes(key(1)))
  assert.deepEqual(saved.relays, ["wss://r"])
  assert.equal(BATCH_MS, 50)
})

test("#3: with no vault yet nothing is asked", async () => {
  let n = 0
  wantProfile(key(99), () => null, { fetch: async () => { n++ }, delayMs: 5 })
  await wait(20)
  assert.equal(n, 0)
})

test("#3: Mention and a quote's author go through the batch", () => {
  assert.match(read("components/NoteText.jsx"), /wantProfile\(pubkey, quoteSource, \{ save: !memoryOnly \}\)/)
  assert.match(read("components/QuotedNote.jsx"), /wantProfile\(ev\.pubkey, quoteSource, \{ save: !memoryOnly \}\)/)
  assert.doesNotMatch(read("components/NoteText.jsx"), /fetchProfiles\(/)
})

test("#8 queryMany: every filter to every relay in one subscribeMap (one REQ a relay), ends on EOSE", async () => {
  let reqs, closed = false
  const p = { subscribeMap: (requests, params) => { reqs = requests; setTimeout(() => { params.onevent({ id: "x" }); params.oneose() }, 1); return { close: () => { closed = true } } } }
  const evs = await queryMany(["wss://a", "wss://b"], [{ kinds: [9735], "#e": ["1"] }, { kinds: [9735], "#e": ["2"] }], { p })
  assert.deepEqual(evs, [{ id: "x" }])
  assert.equal(reqs.length, 4)
  assert.deepEqual(reqs.map(r => r.url), ["wss://a", "wss://a", "wss://b", "wss://b"])
  assert.ok(closed)
  assert.deepEqual(await queryMany([], [{}], { p }), [])
})

test("#2: your own profile asks the whole page once a page load, then only since just before the newest held", () => {
  forgetOwnAsked()
  const me = key(5), held = [{ created_at: 1000 }, { created_at: 3000 }, { created_at: 2000 }]
  assert.equal(ownSince(me, held), undefined, "first open: the whole page")
  markOwnAsked(me)
  assert.equal(ownSince(me, held), 3000 - SINCE_SLACK_S)
  assert.equal(ownSince(me, []), undefined, "nothing held: the whole page")
  assert.equal(ownSince(key(6), held), undefined, "another account")
})

test("#2: syncOwn, syncOwnPage and Tagged pass `since` on to the relays", async () => {
  const filters = []
  const query = async (r, f) => { filters.push(f); return [] }
  await syncOwn({ outbox: {} }, key(1), ["wss://a"], { since: 500, query })
  await syncOwnPage({ outbox: {} }, key(1), ["wss://a"], { since: 500, kinds: [6], query })
  assert.deepEqual(filters.map(f => f.since), [500, 500, 500])
  filters.length = 0
  await syncOwn({ outbox: {} }, key(1), ["wss://a"], { query })
  assert.ok(filters.every(f => !("since" in f)), "no since: the whole page")
  // Tagged: nothing kept yet asks everything; once a note is kept, only from just before it.
  const P = key(7), note = { id: key(8), kind: 1, pubkey: key(9), created_at: 4000, tags: [["p", P]] }
  const tq = []
  await fetchTagged(P, [], { newerOnly: true, query: async (r, f) => { tq.push(f); return [note] } })
  await fetchTagged(P, [], { newerOnly: true, query: async (r, f) => { tq.push(f); return [] } })
  assert.equal(tq[0].since, undefined)
  assert.equal(tq[1].since, 4000 - SINCE_SLACK_S)
  assert.equal((await fetchTagged(P, [], { newerOnly: true, query: async () => [] })).length, 1, "the kept note stays in the list")
})

test("#6: a profile keeps one live subscription for its owner's notes and reposts; others' notes are dropped", () => {
  let got = null
  const close = () => {}
  const watch = o => { got = o; return close }
  const P = key(3), seen = []
  assert.equal(watchProfile({ pubkey: P, relays: ["wss://a"], onNotes: evs => seen.push(...evs), watch }), close)
  assert.deepEqual(got.filters, [{ kinds: [1, 6], authors: [P] }])
  assert.equal(got.keep({ pubkey: P, kind: 1 }), true)
  assert.equal(got.keep({ pubkey: P, kind: 7 }), false)
  assert.equal(got.keep({ pubkey: key(4), kind: 1 }), false)
  got.onNotes([{ pubkey: P, id: "a" }, { pubkey: key(4), id: "b" }])
  assert.deepEqual(seen.map(e => e.id), ["a"])
})

test("#6: both profile screens watch live, and your own no longer looks again on a timer", () => {
  const own = read("screens/ProfileScreen.jsx"), other = read("screens/PersonScreen.jsx")
  assert.match(own, /watchProfile\(\{\n    pubkey: me, relays: writeRelays,\n    save: evs => storeAll\(vault\.outbox, evs\),\n    onNotes: evs => notes\.prepend\(evs\)/)
  assert.match(own, /useAutoLook\([^\n]*\{ every: 0 \}\)/)
  assert.doesNotMatch(own, /PROFILE_RECHECK_MS/)
  assert.match(other, /onNotes: evs => \{ keepPersonNotes\(pubkey, evs\); notes\.prepend\(evs\) \}/)
})

test("auto-look with every 0 sets no timer but still looks on coming back online", () => {
  const was = globalThis.setInterval, listeners = {}
  let timers = 0
  globalThis.setInterval = () => { timers++; return 1 }
  const add = globalThis.addEventListener, remove = globalThis.removeEventListener
  globalThis.addEventListener = (k, f) => { listeners[k] = f }
  globalThis.removeEventListener = () => {}
  let looks = 0
  try {
    const stop = lookInFront(() => { looks++ }, { every: 0, doc: { hidden: false, addEventListener() {}, removeEventListener() {} } })
    assert.equal(timers, 0)
    listeners.online()
    stop()
  } finally { globalThis.setInterval = was; globalThis.addEventListener = add; globalThis.removeEventListener = remove }
  return wait(5).then(() => assert.equal(looks, 1))
})

test("#4: a memo card skips a redraw for the same note (a new copy, same id) and draws for a new note or prop", () => {
  const Card = memoCard(function Inner() { return null })
  const c = new Card({})
  const ev = { id: "a", kind: 1 }
  c.props = { event: ev, memoryOnly: false }
  assert.equal(c.shouldComponentUpdate({ event: { ...ev }, memoryOnly: false }), false)
  assert.equal(c.shouldComponentUpdate({ event: { id: "b", kind: 1 }, memoryOnly: false }), true)
  assert.equal(c.shouldComponentUpdate({ event: ev, memoryOnly: true }), true)
  assert.equal(c.shouldComponentUpdate({ event: ev, memoryOnly: false, extra: 1 }), true)
})

test("#4: profile tabs draw memo cards, and the opening list draws at most every DRAW_MS", () => {
  const tabs = read("screens/ProfileTabs.jsx")
  assert.match(tabs, /list\.map\(n => <NoteCardMemo key=\{n\.id\}/)
  assert.match(tabs, /if \(!drawn\) \{ drawn = true; setItems\(evs\) \} else s\.drawAt \?\?= setTimeout\(draw, DRAW_MS\)/)
  assert.match(tabs, /export const DRAW_MS = 150/)
})
