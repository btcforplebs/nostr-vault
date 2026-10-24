// The Messages badge (sidebar count, Vault tab dot): unread messages for the signed-in account only, blocked people
// left out, "99+" past 99.
import test from "node:test"
import assert from "node:assert/strict"
import { accountUnread, badgeCount } from "../src/components/useUnreadTotal.js"
import { forgetReadCache } from "../src/net/dm-read.js"

const me = "a".repeat(64), alice = "b".repeat(64), bob = "c".repeat(64), other = "d".repeat(64)
const storage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) } }
const msg = (id, from, peer, at) => [id, { id, from, peer, at }]

test("counts others' unread messages for this account, minus blocked people", () => {
  forgetReadCache()
  const opts = { storage: storage(), clock: () => 100 }
  const messages = new Map([msg("1", alice, alice, 200), msg("2", alice, alice, 201), msg("3", bob, bob, 202), msg("4", me, alice, 203), msg("5", alice, alice, 50)])
  const trusted = new Set([alice, bob]) // both in the web: a stranger's would be a Request (dm-trust.test.mjs)
  assert.equal(accountUnread({ pubkey: me, messages }, me, new Set(), opts, trusted), 3) // 5 is before the first open; 4 is mine
  assert.equal(accountUnread({ pubkey: me, messages }, me, new Set([bob]), opts, trusted), 2)
})

test("messages loaded for another account, or no one signed in, count as none", () => {
  forgetReadCache()
  const messages = new Map([msg("1", alice, alice, 200)])
  assert.equal(accountUnread({ pubkey: other, messages }, me, new Set(), { storage: storage(), clock: () => 100 }), 0)
  assert.equal(accountUnread({ pubkey: null, messages }, undefined, new Set()), 0)
})

test("the badge says 99+ past 99", () => {
  assert.equal(badgeCount(7), "7")
  assert.equal(badgeCount(99), "99")
  assert.equal(badgeCount(100), "99+")
})
