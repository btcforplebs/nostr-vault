// The Vault mode menu's New marks: what others sent after each mode was last opened, never your own or a blocked
// person's, nothing on a first look, and the mode on screen never marked.
import test from "node:test"
import assert from "node:assert/strict"
import { modeOfKind, newestByMode, readSeen, writeSeen, markSeen, baseline, newModes } from "../src/net/vault-new.js"

const ME = "a".repeat(64), B = "b".repeat(64), X = "c".repeat(64)
const ev = (pubkey, kind, created_at) => ({ id: `${pubkey}${kind}${created_at}`, pubkey, kind, created_at, tags: [] })

test("kinds go to the phone's modes", () => {
  assert.deepEqual([7, 9735, 30023, 9802, 1, 6, 1111, 4].map(modeOfKind), ["likes", "zaps", "articles", "highlights", "notes", "notes", "notes", null])
})

test("newest arrival per mode from others; activity is the newest of all", () => {
  const n = newestByMode([ev(B, 7, 10), ev(B, 7, 30), ev(B, 1, 20), ev(ME, 1, 99), ev(X, 9735, 50)], ME, new Set([X]))
  assert.deepEqual(n, { likes: 30, notes: 20, activity: 30 })
})

test("first look takes everything as seen; later arrivals light their mode, not the one on screen", () => {
  const first = baseline({ likes: 30, notes: 20, activity: 30 })
  assert.deepEqual([...newModes({ likes: 30, notes: 20, activity: 30 }, first)], [])
  const later = { likes: 40, notes: 20, activity: 40 }
  assert.deepEqual([...newModes(later, first, { current: "notes" })].sort(), ["activity", "likes"])
  assert.deepEqual([...newModes(later, first, { current: "likes" })], ["activity"])
  assert.deepEqual([...newModes(later, markSeen(first, "likes", 40), { current: "notes" })], ["activity"])
  assert.equal(markSeen({ likes: 50 }, "likes", 40).likes, 50, "never moved back")
})

test("followers light only after a newer follower than the last look", () => {
  assert.ok(newModes({}, {}, { followersAt: 20, followersSeen: 10 }).has("followers"))
  assert.ok(!newModes({}, {}, { followersAt: 20, followersSeen: 20 }).has("followers"))
  assert.ok(!newModes({}, {}, { current: "followers", followersAt: 20, followersSeen: 10 }).has("followers"))
})

test("marks are kept per account", () => {
  const store = new Map(), storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  assert.equal(readSeen(ME, storage), null)
  writeSeen(ME, { likes: 5 }, storage)
  assert.deepEqual(readSeen(ME, storage), { likes: 5 })
  assert.equal(readSeen(B, storage), null)
  store.set(`nv-vault-seen:${B}`, "{bad")
  assert.equal(readSeen(B, storage), null)
})
