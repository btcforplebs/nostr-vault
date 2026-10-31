// New Poll (kind 1068): the iPhone's PollDraft rules and tags, read back by the web's own poll card, and that it signs,
// stores and sends as a poll. Throwaway keys and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishKind } from "../src/net/sync.js"
import { parsePoll } from "../src/components/polls.js"
import { MAX_RELAYS, POLL_KIND, buildPoll, closingHint, emptyPoll, endsAt, filledOptions, hasPoll, pollComplete, pollDraftOf, pollHint, pollRelaysFor, randomOptionId } from "../src/screens/compose/poll.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { composeType } = await import("../src/screens/compose/ComposeKinds.jsx")
await import("../src/screens/ComposeScreen.jsx")

const NOW = Date.UTC(2026, 9, 31, 12, 0, 0)
const poll = patch => ({ ...emptyPoll(NOW), ...patch })
const ids = () => { let n = 0; return () => `opt${n++}` }

test("a fresh poll: a blank question, two blank options, single choice, closing in a day; it says nothing yet", () => {
  const d = emptyPoll(NOW)
  assert.deepEqual([d.question, d.options, d.multiple, d.closes], ["", ["", ""], false, "1d"])
  assert.equal(hasPoll(d), false)
  assert.equal(pollHint(d), null)
  assert.equal(pollComplete(d, NOW), false)
})

test("PollDraft.isComplete: a question, two different options (case aside), at most ten, an end still ahead", () => {
  assert.equal(pollComplete(poll({ question: "Q?", options: ["Yes", "No"] }), NOW), true)
  assert.equal(pollComplete(poll({ question: " ", options: ["Yes", "No"] }), NOW), false)
  assert.equal(pollComplete(poll({ question: "Q?", options: ["Yes", "  "] }), NOW), false)
  assert.equal(pollComplete(poll({ question: "Q?", options: ["Yes", "yes "] }), NOW), false)
  assert.equal(pollComplete(poll({ question: "Q?", options: Array.from({ length: 11 }, (_, i) => `o${i}`) }), NOW), false)
  assert.equal(pollComplete(poll({ question: "Q?", options: ["a", "b"], closes: "custom", customEnd: "2020-01-01T00:00" }), NOW), false)
  assert.equal(pollComplete(poll({ question: "Q?", options: ["a", "b"], closes: "never" }), NOW), true)
})

test("the hints say what's missing, in the iPhone's words", () => {
  assert.equal(pollHint(poll({ options: ["a", ""] })), "Add a question to post.")
  assert.equal(pollHint(poll({ question: "Q?" })), "Fill in at least two options to post.")
  assert.equal(pollHint(poll({ question: "Q?", options: ["Same", "same"] })), "Two options are the same.")
  assert.equal(pollHint(poll({ question: "Q?", options: ["a", "b"] })), null)
  assert.equal(closingHint(poll({ closes: "custom", customEnd: "2020-01-01T00:00" }), NOW), "Pick a closing time that's still ahead.")
  assert.equal(closingHint(poll({ closes: "1h" }), NOW), null)
})

test("closing: counted from Post; Never leaves no end", () => {
  const s = NOW / 1000
  assert.equal(endsAt(poll({ closes: "1h" }), NOW), s + 3600)
  assert.equal(endsAt(poll({ closes: "1d" }), NOW), s + 86400)
  assert.equal(endsAt(poll({ closes: "3d" }), NOW), s + 3 * 86400)
  assert.equal(endsAt(poll({ closes: "1w" }), NOW), s + 7 * 86400)
  assert.equal(endsAt(poll({ closes: "never" }), NOW), null)
  const end = new Date(2026, 10, 2, 18, 30) // local time, as the picker gives it
  assert.equal(endsAt(poll({ closes: "custom", customEnd: "2026-11-02T18:30" }), NOW), Math.floor(end.getTime() / 1000))
})

test("buildPoll: an option per filled label with its own id, the relays, polltype, endsAt; the web's card reads it back", () => {
  const d = poll({ question: "  Lunch?  ", options: ["Tacos", "", " Pizza ", "Soup"], multiple: true, closes: "1h" })
  const { content, tags } = buildPoll(d, ["wss://a.example", "wss://b.example"], { makeId: ids(), now: NOW })
  assert.equal(content, "Lunch?")
  assert.deepEqual(tags, [["option", "opt0", "Tacos"], ["option", "opt1", "Pizza"], ["option", "opt2", "Soup"],
    ["relay", "wss://a.example"], ["relay", "wss://b.example"], ["polltype", "multiplechoice"], ["endsAt", String(NOW / 1000 + 3600)]])
  const read = parsePoll({ kind: POLL_KIND, id: "x", pubkey: "y", content, tags })
  assert.deepEqual(read.options.map(o => o.label), ["Tacos", "Pizza", "Soup"])
  assert.equal(read.multiple, true); assert.equal(read.endsAt, NOW / 1000 + 3600); assert.deepEqual(read.relays, ["wss://a.example", "wss://b.example"])
  const single = buildPoll(poll({ question: "Q", options: ["a", "b"], closes: "never" }), [], { makeId: ids(), now: NOW })
  assert.deepEqual(single.tags.slice(-1), [["polltype", "singlechoice"]])
})

test("option ids: 9 of a-z0-9, and a repeat is drawn again", () => {
  assert.match(randomOptionId(), /^[a-z0-9]{9}$/)
  const seq = ["dup", "dup", "fresh"]
  const { tags } = buildPoll(poll({ question: "Q", options: ["a", "b"] }), [], { makeId: () => seq.shift(), now: NOW })
  assert.deepEqual(tags.filter(t => t[0] === "option").map(t => t[1]), ["dup", "fresh"])
})

test("the poll's relays: your public wss write relays, deduplicated, at most four; else the defaults", () => {
  assert.deepEqual(pollRelaysFor(["wss://a.example", "WSS://A.example", "ws://insecure.example", "wss://localhost:3355", "wss://192.168.1.4", "wss://b.example"]),
    ["wss://a.example", "wss://b.example"])
  assert.equal(pollRelaysFor(["wss://1.example", "wss://2.example", "wss://3.example", "wss://4.example", "wss://5.example"]).length, MAX_RELAYS)
  const fallback = pollRelaysFor(["ws://localhost:3355"])
  assert.ok(fallback.length > 0 && fallback.every(r => r.startsWith("wss://")))
})

test("the draft keeps the form as typed; ?type=poll opens the poll composer", () => {
  const d = poll({ question: "Q", options: ["a", ""], multiple: true, closes: "custom", customEnd: "2026-11-02T18:30" })
  assert.deepEqual(pollDraftOf(d), { question: "Q", options: ["a", ""], multiple: true, closes: "custom", customEnd: "2026-11-02T18:30" })
  assert.deepEqual(filledOptions(d), ["a"])
  assert.equal(composeType("#/compose?type=poll"), "poll")
})

test("publishKind signs a kind 1068 with the poll's tags (no client tag), stores it, then sends it", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const stored = [], sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push(...urls); return urls.map(() => Promise.resolve("")) })
  const vault = { outbox: { event: async e => { stored.push(e); return { ok: true } } } }
  const { content, tags } = buildPoll(poll({ question: "Q?", options: ["a", "b"] }), ["wss://w.example"], { now: NOW })
  const res = await publishKind(vault, { signEvent: async tpl => finalizeEvent(tpl, sk) }, pk, POLL_KIND, content, ["wss://w.example"], tags)
  assert.equal(res.event.kind, POLL_KIND)
  assert.ok(verifyEvent(res.event))
  assert.equal(res.event.tags.some(t => t[0] === "client"), false)
  assert.ok(parsePoll(res.event))
  assert.deepEqual(stored.map(e => e.id), [res.event.id])
  assert.ok(sent.includes("wss://w.example"))
})
