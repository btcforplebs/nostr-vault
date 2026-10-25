// Who reaches the Messages inbox (net/dm-trust.js, ported from the iPhone's DMTrust): the Web of Trust, or a
// conversation the user wrote in. Following the user is not trust; an empty trust set fails closed.
import test from "node:test"
import assert from "node:assert/strict"
import { isInbox, split, splitConversations, requestPeers, wroteIn } from "../src/net/dm-trust.js"
import { trustedWeb } from "../src/net/notifications.js"
import { conversations } from "../src/net/dms.js"
import { accountUnread } from "../src/components/useUnreadTotal.js"
import { forgetReadCache } from "../src/net/dm-read.js"

const me = "a".repeat(64), friend = "b".repeat(64), stranger = "c".repeat(64), fan = "d".repeat(64), fof = "e".repeat(64)
const own = new Set([me])
const msg = (id, from, peer, at) => [id, { id, from, peer, at, content: id }]
const storage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) } }

test("someone in the trust set reaches the inbox", () => {
  assert.equal(isInbox(friend, false, new Set([friend]), own), true)
})

test("a stranger waits under Requests", () => {
  assert.equal(isInbox(stranger, false, new Set([friend]), own), false)
})

test("someone who only follows the user waits under Requests", () => {
  // The fan follows me; my follow (friend) follows only fof. trustedWeb is built from my follows' lists, never from
  // who follows me, so the fan is not in it.
  const lists = new Map([[friend, { kind: 3, pubkey: friend, tags: [["p", fof]] }]])
  const trusted = trustedWeb([friend], lists)
  assert.equal(trusted.has(fan), false)
  assert.equal(isInbox(fan, false, trusted, own), false)
  assert.equal(isInbox(fof, false, trusted, own), true)
})

test("a conversation the user wrote in reaches the inbox, trusted or not", () => {
  assert.equal(isInbox(stranger, true, new Set([friend]), own), true)
  const messages = new Map([msg("1", stranger, stranger, 10), msg("2", me, stranger, 11), msg("3", fan, fan, 12)])
  assert.deepEqual([...wroteIn(messages, me)], [stranger])
  assert.deepEqual([...requestPeers(messages, me, new Set([friend]))], [fan])
})

test("with no trust set, only conversations the user wrote in reach the inbox", () => {
  const messages = new Map([msg("1", friend, friend, 10), msg("2", me, stranger, 11), msg("3", fan, fan, 12), msg("4", me, me, 13)])
  const { inbox, requests } = splitConversations(conversations(messages), messages, me, new Set())
  assert.deepEqual(inbox.map(c => c.peer).sort(), [me, stranger].sort())
  assert.deepEqual(requests.map(c => c.peer).sort(), [fan, friend].sort())
})

test("keys match whatever their case", () => {
  assert.equal(isInbox(friend.toUpperCase(), false, new Set([friend]), own), true)
  assert.equal(isInbox(me.toUpperCase(), false, new Set(), own), true)
  assert.equal(isInbox(friend, false, new Set(), new Set([friend.toUpperCase()])), true)
})

test("split keeps the order of both lists", () => {
  const rows = [stranger, friend, fan, me].map(peer => ({ peer }))
  const { inbox, requests } = split(rows, new Set([friend]), own, c => c.peer, () => false)
  assert.deepEqual(inbox.map(c => c.peer), [friend, me])
  assert.deepEqual(requests.map(c => c.peer), [stranger, fan])
})

test("requests never count towards the unread badge", () => {
  forgetReadCache()
  const opts = { storage: storage(), clock: () => 100 }
  const messages = new Map([msg("1", friend, friend, 200), msg("2", fan, fan, 201), msg("3", fan, fan, 202), msg("4", stranger, stranger, 203)])
  assert.equal(accountUnread({ pubkey: me, messages }, me, new Set(), opts, new Set([friend])), 1)
  assert.equal(accountUnread({ pubkey: me, messages }, me, new Set(), opts, new Set()), 0) // fails closed
})
