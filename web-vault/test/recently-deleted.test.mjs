// Recently Deleted: a copy of your own post kept when deleteNote's kind 5 went out (not for replaceable kinds or other
// people's), dropped after 30 days, posted again as a new event without nonce/expiration, and the copy kept when no
// relay took it. Throwaway keys and fake stores: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { deleteNote } from "../src/net/actions.js"
import { keepsCopy, republishTemplate, keepDeletedCopy, deletedPosts, undelete, deletedDbName } from "../src/net/recently-deleted.js"

const SK = generateSecretKey(), ME = getPublicKey(SK), OTHER = getPublicKey(generateSecretKey())
const memStore = () => { const m = new Map(); return { m, all: async () => [...m.values()], put: async p => { m.set(p.id, p) }, remove: async id => { m.delete(id) } } }
const ctx = { session: { pubkey: ME }, account: { relays: { read: [], write: ["wss://w.example"] } }, signer: { signEvent: async t => finalizeEvent(t, SK) }, vault: { outbox: { query: async () => [], event: async () => ({ ok: true }) } } }
const note = (kind = 1, tags = [["e", "a".repeat(64)], ["nonce", "1", "20"], ["expiration", "1"], ["t", "x"]]) => finalizeEvent({ kind, content: "hello", tags, created_at: 1000 }, SK)

test("replaceable and addressable kinds get no copy", () => {
  assert.deepEqual([1, 6, 7, 1111, 20].map(keepsCopy), [true, true, true, true, true])
  assert.deepEqual([0, 3, 10002, 19999, 30023, 39999].map(keepsCopy), [false, false, false, false, false, false])
  assert.equal(deletedDbName(ME), `haven:${ME}:deleted`)
})

test("a copy is kept for your own post only, and dropped after 30 days", async () => {
  const s = memStore()
  assert.equal(await keepDeletedCopy(ctx, note(), s, 5000), true)
  assert.equal(await keepDeletedCopy(ctx, { ...note(), pubkey: OTHER }, s, 5000), false)
  assert.equal(await keepDeletedCopy(ctx, note(30023), s, 5000), false)
  assert.equal((await deletedPosts(ME, s, 5000 + 29 * 86400)).length, 1)
  assert.equal((await deletedPosts(ME, s, 5000 + 31 * 86400)).length, 0)
  assert.equal(s.m.size, 0, "the old copy is removed, not just hidden")
})

test("un-delete posts the same kind, text and tags as a new event, without nonce and expiration", async () => {
  const s = memStore(), n = note()
  await keepDeletedCopy(ctx, n, s, 5000)
  let sent
  const ev = await undelete(ctx, (await deletedPosts(ME, s, 5000))[0], { store: s, publish: async (c, t) => { sent = t; return { event: finalizeEvent(t, SK) } } })
  assert.deepEqual(sent.tags, [["e", "a".repeat(64)], ["t", "x"]])
  assert.equal(sent.kind, 1); assert.equal(sent.content, "hello")
  assert.ok(sent.created_at > n.created_at)
  assert.notEqual(ev.id, n.id)
  assert.equal(s.m.size, 0)
  assert.deepEqual(republishTemplate({ kind: 1, content: "x", tags: [] }, 7), { kind: 1, content: "x", created_at: 7, tags: [] })
})

test("no relay took it: the copy stays; another account's copy isn't posted", async () => {
  const s = memStore()
  await keepDeletedCopy(ctx, note(), s, 5000)
  const [p] = await deletedPosts(ME, s, 5000)
  await assert.rejects(undelete(ctx, p, { store: s, publish: async () => { throw new Error("No relay took it") } }), /No relay/)
  assert.equal(s.m.size, 1)
  await assert.rejects(undelete(ctx, { ...p, pubkey: OTHER }, { store: s, publish: () => assert.fail("posted") }), /another account/)
})

test("deleteNote still deletes when the copy can't be kept (no IndexedDB here)", async t => {
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.resolve("")))
  await deleteNote(ctx, note())
})
