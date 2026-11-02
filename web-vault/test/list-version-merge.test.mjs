// Recover a List's merge rules: entries compare by type and value (Lazarus delta rule), the current list is always in
// the merge, a duplicate keeps the current form, private in any version stays private, an entry the user removed in
// an ordinary edit comes back unticked while one lost to a wipe comes back ticked, empty versions can't be picked,
// and nothing merges a relay list. Throwaway keys; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import {
  itemKey, normUrl, mergeKind, shrank, openVersion, isEmpty, pickProblem, deltaOf, buildMerge, mergedTags, mergeSummary, hasPrivate,
} from "../src/net/list-version-merge.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const KEY = nip44.v2.utils.getConversationKey(SK, ME)
const P = n => n.toString(16).padStart(64, "0")
const ev = (kind, tags, created_at, content = "") => finalizeEvent({ kind, created_at, tags, content }, SK)
const enc = tags => nip44.v2.encrypt(JSON.stringify(tags), KEY)
const open = c => nip44.v2.decrypt(c, KEY)
const follows = (ns, at, extra = []) => ev(3, [...ns.map(n => ["p", P(n)]), ...extra], at, '{"relays":"keep"}')

test("entries compare by type and value: hints, petnames, case and relay spelling are the same entry", () => {
  assert.equal(itemKey(3, ["p", P(1).toUpperCase(), "wss://hint"]), itemKey(3, ["p", P(1), "", "alice"]))
  assert.equal(itemKey(10050, ["relay", "wss://Relay.Example:443//a/"]), itemKey(10050, ["relay", "wss://relay.example/a"]))
  assert.equal(normUrl("WSS://Relay.Example/"), "wss://relay.example")
  assert.equal(normUrl("wss://relay.example:7777/"), "wss://relay.example:7777")
  assert.equal(itemKey(3, ["d", "x"]), null, "a tag naming the list is not an entry")
  assert.equal(itemKey(3, ["p"]), null, "a tag with no value is not an entry")
  assert.notEqual(itemKey(10000, ["t", "x"]), itemKey(10000, ["word", "x"]))
})

test("the wipe rule matches haven-go listShrank", () => {
  const ten = follows([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 1)
  assert.ok(shrank(ten, follows([], 2)), "emptied")
  assert.ok(shrank(ten, follows([1, 2, 3, 4], 2)), "under half of 10+")
  assert.ok(!shrank(ten, follows([1, 2, 3, 4, 5], 2)), "exactly half is an edit")
  assert.ok(!shrank(follows([1, 2, 3, 4], 1), follows([1], 2)), "a small list edited down is not a wipe")
  assert.ok(shrank(ev(10000, [], 1, "x".repeat(1200)), ev(10000, [], 2, "x".repeat(500))), "encrypted part halved")
})

test("a version's private part is opened; an entry public and private is one private entry", async () => {
  const m = ev(10000, [["p", P(1)], ["t", "spam"]], 10, enc([["p", P(1)], ["word", "Scam"]]))
  const v = await openVersion(m, open)
  assert.equal(v.reason, "")
  assert.equal(v.entries.size, 3)
  assert.equal(v.entries.get(itemKey(10000, ["p", P(1)])).private, true)
  const shut = await openVersion(m, null)
  assert.match(shut.reason, /can't open/)
  assert.ok(!isEmpty(shut), "an unopened private part may hold anything: not empty")
  assert.match(pickProblem(shut), /Can't be merged/)
  const bad = await openVersion(ev(10000, [], 10, "not-ciphertext"), open)
  assert.match(bad.reason, /couldn't be opened/)
  assert.ok(!hasPrivate(follows([1], 1)), "kind 3 content is relay hints, never a private part")
  assert.equal(mergeKind(10002), undefined, "only Settings › Relays sends a 10002")
})

test("empty versions are never offered", async () => {
  const v = await openVersion(follows([], 5), open)
  assert.ok(isEmpty(v))
  assert.match(pickProblem(v), /Empty/)
})

test("merge: current always in, each entry once, current form wins, delta per version", async () => {
  const cur = await openVersion(follows([1, 2], 30, [["p", P(1), "wss://now-hint"]]), open)
  const old = await openVersion(ev(3, [["p", P(1), "wss://old-hint"], ["p", P(3)], ["p", P(4)]], 20), open)
  assert.deepEqual(deltaOf(old, cur), { added: 2, removed: 1 })
  const rows = buildMerge({ current: cur, picked: [old], all: [cur, old] })
  assert.deepEqual(rows.map(r => r.tag[1]), [P(1), P(2), P(3), P(4)], "current order first, then what comes back")
  assert.equal(rows[0].tag[2], undefined, "the current list's own tag for 1 (its first p tag) is kept, not the old hint")
  assert.deepEqual(rows.map(r => r.status), ["current", "current", "removed", "removed"])
})

test("a later remove: an ordinary edit comes back unticked, a wipe comes back ticked", async () => {
  const many = Array.from({ length: 12 }, (_, i) => i + 1)
  const v1 = await openVersion(follows([...many, 99], 10), open) // had 99
  const v2 = await openVersion(follows(many, 20), open) // user unfollowed 99: an edit
  const v3 = await openVersion(follows([1], 30), open) // a wipe: 12 -> 1
  const rows = buildMerge({ current: v3, picked: [v1, v2], all: [v3, v2, v1] })
  const by = Object.fromEntries(rows.map(r => [r.tag[1], r]))
  assert.equal(by[P(99)].status, "removed")
  assert.equal(by[P(99)].ticked, false, "unfollowed on purpose: not brought back unless ticked")
  assert.equal(by[P(99)].at, 20)
  assert.equal(by[P(5)].status, "lost")
  assert.equal(by[P(5)].ticked, true)
  assert.equal(by[P(5)].at, 30)
  assert.equal(by[P(1)].status, "current")
  const sum = mergeSummary(3, rows)
  assert.deepEqual(sum, { total: 12, added: 11, removed: 0, remutes: 0 })
})

test("no current list: what comes back is ticked", async () => {
  const v1 = await openVersion(follows([1, 2], 10), open)
  const v2 = await openVersion(follows([2, 3], 20), open)
  const rows = buildMerge({ current: null, picked: [v1, v2], all: [v2, v1] })
  const p1 = rows.find(r => r.tag[1] === P(1))
  assert.equal(p1.status, "removed", "v2 dropped 1 in an edit")
  assert.equal(rows.find(r => r.tag[1] === P(3)).status, "back")
})

test("private in any merged version stays private, and goes in the private tags", async () => {
  const cur = await openVersion(ev(10000, [["p", P(1)]], 30, enc([["word", "x"]])), open)
  const old = await openVersion(ev(10000, [["t", "nsfw"]], 20, enc([["p", P(1)], ["p", P(2)]])), open)
  const rows = buildMerge({ current: cur, picked: [old], all: [cur, old] })
  assert.equal(rows.find(r => r.tag[1] === P(1)).private, true, "public now, private before: kept private")
  for (const r of rows) r.ticked = true
  const { tags, privateTags } = mergedTags(rows, cur)
  assert.deepEqual(tags, [["t", "nsfw"]])
  assert.deepEqual(privateTags.map(t => t[1]).sort(), [P(1), P(2), "x"].sort())
  assert.equal(mergeSummary(10000, rows).remutes, 1, "P(2) is muted again: said before Save")
})

test("an unopenable older private part makes the next version's removal unknown, not a removal", async () => {
  const v1 = await openVersion(ev(10000, [], 10, enc([["p", P(7)]])), open)
  const v2 = await openVersion(ev(10000, [["p", P(1)]], 20, "garbage"), open)
  const cur = await openVersion(ev(10000, [["p", P(1)], ["p", P(2)]], 30), open)
  const rows = buildMerge({ current: cur, picked: [v1], all: [cur, v2, v1] })
  const r = rows.find(x => x.tag[1] === P(7))
  assert.equal(r.status, "back")
  assert.equal(r.ticked, true)
})

test("tags: the current list's own tags kept first, unticked rows dropped", async () => {
  const cur = await openVersion(ev(10063, [["server", "https://a.example"], ["server", "https://b.example"], ["client", "x"]], 30), open)
  const old = await openVersion(ev(10063, [["server", "https://A.example/"], ["server", "https://c.example"]], 20), open)
  const rows = buildMerge({ current: cur, picked: [old], all: [cur, old] })
  assert.equal(rows.length, 3, "a.example spelled two ways is one server")
  rows.find(r => r.tag[1] === "https://b.example").ticked = false
  rows.find(r => r.tag[1] === "https://c.example").ticked = true
  const { tags, privateTags } = mergedTags(rows, cur)
  assert.deepEqual(tags, [["client", "x"], ["server", "https://a.example"], ["server", "https://c.example"]])
  assert.deepEqual(privateTags, [])
  assert.deepEqual(mergeSummary(10063, rows), { total: 2, added: 1, removed: 1, remutes: 0 })
})

test("one summary line per version", async () => {
  const { deltaLine } = await import("../src/net/list-version-merge.js")
  assert.equal(deltaLine(3, { added: 340, removed: 2 }), "+340 follows, −2")
  assert.equal(deltaLine(3, { added: 1, removed: 0 }), "+1 follow")
  assert.equal(deltaLine(10000, { added: 0, removed: 3 }), "−3 muted entries")
  assert.equal(deltaLine(10003, { added: 0, removed: 0 }), "Same as now")
})

test("an entry moved to the private part after the picked version comes back private (Tron, PR 1570)", async () => {
  const v1 = await openVersion(ev(10000, [["p", P(5)], ["p", P(6)]], 10), open)
  const v2 = await openVersion(ev(10000, [["p", P(6)]], 20, enc([["p", P(5)]])), open)
  const cur = await openVersion(ev(10000, [], 30), open) // a wipe
  const rows = buildMerge({ current: cur, picked: [v1], all: [cur, v2, v1] })
  const x = rows.find(r => r.tag[1] === P(5))
  assert.equal(x.private, true)
  assert.equal(x.ticked, true)
  const { tags, privateTags } = mergedTags(rows, cur)
  assert.ok(!tags.some(t => t[1] === P(5)), "not in the public tags")
  assert.ok(privateTags.some(t => t[1] === P(5)))
  assert.equal(rows.find(r => r.tag[1] === P(6)).private, false, "an entry never private stays public")
})

test("a newer version not opened yet: what it may hide comes back private; nothing is decrypted until asked", async () => {
  let asked = 0
  const counting = c => { asked++; return open(c) }
  const v1 = await openVersion(ev(10000, [["p", P(5)]], 10), counting)
  const v2 = await openVersion(ev(10000, [], 20, enc([["p", P(5)]])), undefined)
  assert.equal(v2.locked, true)
  assert.equal(asked, 0, "a locked version isn't decrypted")
  assert.ok(!isEmpty(v2) && !pickProblem(v2), "locked is not empty and can be ticked")
  const cur = await openVersion(ev(10000, [["p", P(9)]], 30), counting)
  const rows = buildMerge({ current: cur, picked: [v1], all: [cur, v2, v1] })
  assert.equal(rows.find(r => r.tag[1] === P(5)).private, true)
  assert.equal(rows.find(r => r.tag[1] === P(9)).private, false, "the list now keeps its form")
  // An older unread version can't have hidden it later: no change.
  const v0 = await openVersion(ev(10000, [], 5, enc([["p", P(5)]])), undefined)
  const rows2 = buildMerge({ current: cur, picked: [v1], all: [cur, v1, v0] })
  assert.equal(rows2.find(r => r.tag[1] === P(5)).private, false)
})
