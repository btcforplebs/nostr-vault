// First sign-in's "Getting your vault ready": prepareVault fills Haven step by step and reports each step, a slow
// step lets the app open while it carries on, and a later sign-in skips the screen. Fake Haven routes and fake relays
// (pool mocked): nothing is published. Node can't load .jsx or .css, so a load hook compiles the one and empties the other.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { pool } = await import("../src/net/pool.js")
const { STEPS, prepareVault, hasLocalData, wasPrepared, markPrepared, progressOf, READY_KEY } = await import("../src/net/vault-ready.js")
const { VaultReady, stepDetail } = await import("../src/components/VaultReady.jsx")

Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
const hex = n => n.toString(16).padStart(64, "0")
const ME = "a".repeat(64)
const FOLLOWS = Array.from({ length: 300 }, (_, i) => hex(i + 1))
const now = Math.floor(Date.now() / 1000)
let seq = 0
const ev = (kind, pubkey, tags = [], created_at = now - 60) => ({ id: hex(++seq + 10_000), kind, pubkey, created_at, tags, content: kind === 0 ? JSON.stringify({ name: pubkey.slice(0, 4) }) : "hi", sig: "" })

function memStorage() {
  const m = new Map()
  return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
globalThis.localStorage = memStorage()

/** A Haven route in memory: stores, and answers kinds/authors/limit queries newest first. */
function route() {
  const evs = []
  return {
    evs,
    async event(e) { if (evs.some(x => x.id === e.id)) return { ok: false, message: "duplicate: have it" }; evs.push(e); return { ok: true } },
    async query(f) {
      const hit = evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey)) && (!f.until || e.created_at <= f.until))
      return hit.sort((a, b) => b.created_at - a.created_at).slice(0, f.limit ?? Infinity)
    },
  }
}
const vault = () => ({ outbox: route(), feed: route(), inbox: route() })
const empty = { contacts: undefined, follows: [], relays: { read: [], write: [] } }

/** Relays that know the account, its notes, its follows' notes and profiles. `slow` ids never answer. */
function relays(t, { slow = new Set() } = {}) {
  const asked = []
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(pool, "querySync", async (_urls, f) => {
    asked.push(f)
    const k = f.kinds.join()
    if (k === "0,3,10002") return slow.has("account") ? new Promise(() => {}) : [ev(0, ME), ev(3, ME, FOLLOWS.map(p => ["p", p]))]
    if (k === "1" || k === "30023") return slow.has("notes") ? new Promise(() => {}) : k === "1" ? [ev(1, ME), ev(1, ME)] : []
    if (k === "0") return slow.has("profiles") ? new Promise(() => {}) : f.authors.map(p => ev(0, p))
    return slow.has("feed") ? new Promise(() => {}) : f.authors.slice(0, 3).map(p => ev(1, p))
  })
  return asked
}

test("prepareVault fills the account, own notes, follows' notes and profiles, reporting each step", async t => {
  localStorage.m.clear()
  relays(t)
  const v = vault(), steps = {}, order = []
  const onStep = (id, s) => { steps[id] = { ...steps[id], ...s }; order.push(`${id}:${s.state}`) }
  const { account, fresh } = await prepareVault({ vault: v, pubkey: ME, local: empty, onStep })
  assert.ok(fresh)
  assert.equal(account.follows.length, 300)
  assert.equal(order[0], "account:active")
  for (const id of ["account", "notes", "feed", "profiles"]) assert.equal(steps[id].state, "done", id)
  assert.equal(steps.account.count, 300)
  assert.equal(steps.notes.count, 2)
  assert.deepEqual([steps.feed.done, steps.feed.of], [300, 300])
  assert.deepEqual([steps.profiles.done, steps.profiles.of], [300, 300], "profiles are counted 200 at a time")
  assert.equal(v.outbox.evs.filter(e => e.kind === 1).length, 2)
  assert.ok(v.feed.evs.some(e => e.kind === 1), "follows' notes are in /feed")
  assert.equal(v.feed.evs.filter(e => e.kind === 0).length, 300, "follows' profiles are in /feed")
  assert.ok(wasPrepared(ME), "the next sign-in skips the screen")
  assert.equal(progressOf({ relay: { state: "done" }, ...steps }), 1)
})

test("a step that is too slow lets go, says so, and the others still finish", async t => {
  localStorage.m.clear()
  relays(t, { slow: new Set(["feed"]) })
  const steps = {}
  const onStep = (id, s) => { steps[id] = { ...steps[id], ...s } }
  const limits = { account: 200, notes: 200, feed: 50, profiles: 200 }
  await prepareVault({ vault: vault(), pubkey: ME, local: empty, onStep, limits })
  assert.equal(steps.feed.state, "slow")
  assert.equal(steps.notes.state, "done")
  assert.equal(steps.profiles.state, "done")
  assert.equal(stepDetail("feed", steps.feed), "Finishing in the background")
})

test("an account step that is too slow goes on with what Haven has, and says it isn't fresh", async t => {
  localStorage.m.clear()
  relays(t, { slow: new Set(["account"]) })
  const steps = {}
  const { account, fresh } = await prepareVault({ vault: vault(), pubkey: ME, local: empty, onStep: (id, s) => { steps[id] = s }, limits: { account: 30, notes: 200, feed: 200, profiles: 200 } })
  assert.equal(fresh, false)
  assert.equal(account, empty)
  assert.equal(steps.account.state, "slow")
  assert.equal(steps.feed.state, "done", "no follows known yet: nothing to fetch")
})

test("Haven already holding the follow list and their notes counts as ready", async () => {
  const v = vault()
  assert.equal(await hasLocalData(v, empty), false, "no follow list")
  const account = { contacts: ev(3, ME), follows: [FOLLOWS[0]], relays: { read: [], write: [] } }
  assert.equal(await hasLocalData(v, account), false, "follows, but none of their notes")
  await v.feed.event(ev(1, FOLLOWS[0]))
  assert.equal(await hasLocalData(v, account), true)
  assert.equal(await hasLocalData(v, { ...account, follows: [] }), true, "following nobody: the list is enough")
})

test("the ready list is per account and survives a bad value", () => {
  const s = memStorage()
  assert.equal(wasPrepared(ME, s), false)
  markPrepared(ME, s)
  markPrepared(ME, s)
  assert.equal(s.getItem(READY_KEY), JSON.stringify([ME]))
  assert.equal(wasPrepared("b".repeat(64), s), false)
  s.setItem(READY_KEY, "{not json")
  assert.equal(wasPrepared(ME, s), false)
})

test("progress moves within an active step that counts, and never past a finished whole", () => {
  assert.equal(progressOf({}), 0)
  const one = progressOf({ relay: { state: "done" } })
  assert.equal(one, 1 / STEPS.length)
  const half = progressOf({ relay: { state: "done" }, feed: { state: "active", done: 150, of: 300 } })
  assert.ok(half > one && half < 2 / STEPS.length)
})

// The screen's text, flattened from the vnode tree the component returns.
const flat = n => n == null || n === false ? "" : typeof n === "string" || typeof n === "number" ? String(n) : Array.isArray(n) ? n.map(flat).join("") : typeof n.type === "function" ? flat(n.type(n.props)) : flat(n.props?.children)
function find(n, pred) {
  if (n == null || typeof n !== "object") return null
  if (Array.isArray(n)) { for (const c of n) { const f = find(c, pred); if (f) return f } return null }
  if (typeof n.type === "function") return find(n.type(n.props), pred)
  return pred(n) ? n : find(n.props?.children, pred)
}

test("the screen lists every step with its state, an accessible bar, and Open now", () => {
  let opened = 0
  const steps = { relay: { state: "done" }, account: { state: "done", count: 1038 }, feed: { state: "active", done: 250, of: 1038, count: 412 } }
  const tree = VaultReady({ steps, onOpen: () => opened++ })
  const text = flat(tree)
  assert.match(text, /Getting your vault ready/)
  for (const { title } of STEPS) assert.ok(text.includes(title), title)
  assert.match(text, /Following 1,038/)
  assert.match(text, /250 of 1,038 people · 412 notes saved/)
  assert.match(text, /Starting your relay, done/)
  assert.match(text, /Fetching notes from people you follow, in progress/)
  assert.match(text, /Loading names and pictures, waiting/)
  const bar = find(tree, n => n.props?.role === "progressbar")
  assert.equal(bar.props["aria-valuenow"], Math.round(progressOf(steps) * 100))
  assert.match(bar.props["aria-valuetext"], /fetching notes from people you follow/)
  const current = find(tree, n => n.props?.["aria-current"] === "step")
  assert.match(flat(current), /Fetching notes from people you follow/)
  find(tree, n => n.type === "button").props.onClick()
  assert.equal(opened, 1)
})
