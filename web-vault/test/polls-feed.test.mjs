// The Polls feed (parity #18; iPhone PollsFeedViews.swift, PollStatusFilter): Following / Global, Open / Closed / All.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { statusAdmits, keepPolls, fetchPolls, emptyText, POLL_STATUSES } from "../src/readers/polls.js"

const poll = (id, pubkey, endsAt, at = 100) => ({ id, pubkey, kind: 1068, created_at: at, content: "Q?", tags: [["option", "a", "A"], ["option", "b", "B"], ...(endsAt ? [["endsAt", String(endsAt)]] : [])] })
const A = "a".repeat(64), B = "b".repeat(64)

test("Open / Closed / All, the iPhone's words and order", () => {
  assert.deepEqual(POLL_STATUSES.map(s => s.label), ["All", "Open", "Closed"])
  const open = poll("1", A, 2000), closed = poll("2", A, 500), forever = poll("3", A, null)
  for (const [s, want] of [["all", [1, 1, 1]], ["open", [1, 0, 1]], ["closed", [0, 1, 0]]])
    assert.deepEqual([open, closed, forever].map(p => +statusAdmits(p, s, 1000)), want, s)
  assert.equal(emptyText("closed"), "No closed polls")
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Views/PollsFeedViews.swift", import.meta.url), "utf8")
  assert.ok(swift.includes('"No closed polls"'))
})

test("only real polls by the authors asked for, each once, newest first", () => {
  const bad = { ...poll("x", A), tags: [] }
  assert.deepEqual(keepPolls([poll("1", A, 0, 1), poll("2", B, 0, 2), poll("1", A, 0, 1), bad, { id: "n", kind: 1, pubkey: A }], new Set([A])).map(p => p.id), ["1"])
})

test("Following reads your follows' polls; Global only your web of trust's; none without follows", async () => {
  const asked = []
  const query = async (r, f) => { asked.push(f); return [poll("1", A, 0, 5), poll("2", B, 0, 6)] }
  const vault = { feed: { query: async () => [], event: async () => ({ ok: true }) } }
  const f = await fetchPolls({ scope: "following", me: "m", follows: [A], relays: ["wss://r"], vault, query, online: true })
  assert.deepEqual(f.polls.map(p => p.id), ["1"]); assert.deepEqual(asked[0].authors, [A]); assert.deepEqual(asked[0].kinds, [1068])
  const g = await fetchPolls({ scope: "global", me: "m", follows: [A], relays: ["wss://r"], vault, query, online: true, trustOf: async () => new Set([B]) })
  assert.deepEqual(g.polls.map(p => p.id), ["2"])
  assert.deepEqual((await fetchPolls({ scope: "following", me: "m", follows: [], relays: [], vault, query })).polls, [])
})

test("Polls is in the feed picker (a reader with its own icon) and can be pinned on the rail", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("readers/index.js"), /\{ id: "polls", label: "Polls", Screen: PollsScreen \}/)
  assert.match(src("components/FeedPickerMenu.jsx"), /polls: "M5 20V11/)
  assert.match(src("desktop/rail/rail-favs.js"), /NOT_ON_WEB = new Set\(\[\]\)/)
})
