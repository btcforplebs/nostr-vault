// The guest view (src/guest): a shared post opened by someone who isn't signed in. Which addresses open it, which
// relays it reads, the in-memory stores it reads them into, and that it can't sign anything.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode } from "nostr-tools/nip19"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { GUEST_ONLY, GUEST_RELAYS, guestContext, guestPerson, guestRelays, guestTarget } from "../src/guest/guest.js"
import { memoryStore, memoryVault } from "../src/guest/memory-vault.js"
import { createFipsMedia, setMeshPeople, meshAllowed } from "../src/net/fips-media.js"
import { guestPostDeleted, readDeleted } from "../src/guest/deleted.js"

const ID = "ab".repeat(32)
const SK = generateSecretKey(), PK = getPublicKey(SK)
const note = (fields = {}, sk = SK) => finalizeEvent({ kind: 1, created_at: 100, content: "hi", tags: [], ...fields }, sk)

test("guestTarget: the phone's #/thread/<id> and the desktop's ?note=<id>; anything else opens no post", () => {
  assert.equal(guestTarget(`#/thread/${ID}`), ID)
  assert.equal(guestTarget(`#/thread/${ID}?r=wss://relay.example`), ID)
  assert.equal(guestTarget(`#/feed?note=${ID}`), ID, "the desktop layout rewrites a thread link to its list (routes.js)")
  for (const h of ["", "#/feed", `#/thread/${ID.slice(1)}`, `#/thread/${ID.toUpperCase()}`, `#/profile/${ID}`, `#/dm/${ID}`, "#/thread/nevent1qqq"]) {
    assert.equal(guestTarget(h), null, h)
  }
})

test("guestPerson: #/profile/<pubkey> opens that person (the welcome screen's search); anything else opens nobody", () => {
  assert.equal(guestPerson(`#/profile/${ID}`), ID)
  assert.equal(guestPerson(`#/profile/${ID}?x=1`), ID)
  for (const h of ["", "#/", "#/profile", `#/profile/${ID.slice(1)}`, `#/profile/${ID.toUpperCase()}`, `#/thread/${ID}`, `#/wot/${ID}`, "#/profile/npub1qqq"]) {
    assert.equal(guestPerson(h), null, h)
  }
})

test("guestRelays: a link's wss:// hints to public hosts, at most three, before the thread page's read relays", () => {
  const h = "#/thread/x?r=wss://a.example/&r=ws://plain.example&r=wss://localhost&r=wss://10.0.0.1&r=wss://box.local&r=wss://u:p@b.example&r=wss://b.example&r=wss://c.example&r=wss://d.example"
  assert.deepEqual(guestRelays(h), ["wss://a.example", "wss://b.example", "wss://c.example", ...GUEST_RELAYS])
  assert.deepEqual(guestRelays(`#/thread/${ID}`), GUEST_RELAYS)
  assert.deepEqual(GUEST_RELAYS, ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"],
    "the same relays the thread page reads (thread-page/fetch.js READ_RELAYS)")
})

test("memoryStore: signed events only, NIP-01 filters, newest first with limit, one per replaceable slot", async () => {
  const s = memoryStore()
  const a = note({ created_at: 1 }), b = note({ created_at: 2, tags: [["e", ID]] })
  assert.deepEqual(await s.event(a), { ok: true })
  assert.equal((await s.event(b)).ok, true)
  assert.equal((await s.event({ ...a, content: "forged" })).ok, false, "a changed event fails its signature")
  assert.equal((await s.event(a)).ok, true, "a duplicate is fine")
  assert.deepEqual((await s.query({ kinds: [1] })).map(e => e.id), [b.id, a.id])
  assert.deepEqual((await s.query({ kinds: [1], limit: 1 })).map(e => e.id), [b.id])
  assert.deepEqual((await s.query({ "#e": [ID] })).map(e => e.id), [b.id])
  assert.deepEqual(await s.query({ ids: [ID] }), [])

  const p1 = note({ kind: 0, created_at: 5, content: '{"name":"old"}' }), p2 = note({ kind: 0, created_at: 6, content: '{"name":"new"}' })
  await s.event(p2)
  assert.equal((await s.event(p1)).ok, false, "an older profile doesn't replace a newer one")
  assert.deepEqual((await s.query({ kinds: [0], authors: [PK] })).map(e => e.content), ['{"name":"new"}'])
  const p3 = note({ kind: 0, created_at: 7, content: '{"name":"newest"}' })
  await s.event(p3)
  assert.deepEqual((await s.query({ kinds: [0], authors: [PK] })).map(e => e.content), ['{"name":"newest"}'])
})

test("memoryStore: past its cap the first-stored event goes", async () => {
  const s = memoryStore({ max: 2 })
  const [a, b, c] = [1, 2, 3].map(t => note({ created_at: t }))
  for (const e of [a, b, c]) await s.event(e)
  assert.deepEqual((await s.query({})).map(e => e.id).sort(), [b.id, c.id].sort())
})

test("guestContext: nobody's account, follows no one, reads the given relays, and every signature asks to sign in", async () => {
  const ctx = guestContext(["wss://a.example"])
  assert.equal(ctx.session.pubkey, "", "no pubkey: useBlocks and actions load nothing for it")
  assert.equal(ctx.signer.readOnly, true)
  assert.deepEqual(ctx.account.relays.read, ["wss://a.example"])
  assert.deepEqual(ctx.account.follows, [])
  await assert.rejects(ctx.signer.signEvent({ kind: 1 }), new RegExp(GUEST_ONLY.slice(0, 20)))
  assert.equal(memoryVault().guest, true)
})

test("guest mesh gate: every thread author's photos may use the mesh, nobody else's", () => {
  const other = "cd".repeat(32)
  setMeshPeople(undefined, [PK])
  assert.equal(meshAllowed(PK), true)
  assert.equal(meshAllowed(other), false)
  assert.equal(meshAllowed(""), false)
  setMeshPeople(undefined, [])
})

test("warm: starts the reader for an allowed author with a vault, and only then", async () => {
  const vault = "ef".repeat(32)
  const list = finalizeEvent({ kind: 10063, created_at: 1, content: "", tags: [["server", `fipsmesh://${npubEncode(vault)}/`]] }, SK)
  let starts = 0
  const timers = []
  const mk = (allow, lists) => createFipsMedia({
    allow, query: async (_r, f) => (f.authors.includes(PK) ? lists : []),
    startReader: async () => { starts++; return { getBlob: async () => { throw new Error("unused") }, stop() {} } },
    setTimer: (fn, ms) => { timers.push(ms); return timers.length }, clearTimer: () => {},
  })
  await mk(() => false, [list]).warm([PK])
  assert.equal(starts, 0, "not allowed: no reader")
  await mk(() => true, []).warm([PK])
  assert.equal(starts, 0, "no vault listed: no reader")
  await mk(() => true, [list]).warm(["", PK, PK])
  assert.equal(starts, 1, "allowed with a vault: one reader")
  assert.equal(timers.length, 1, "and its idle stop is armed, so an unused reader doesn't run on")
})

test("a post its author deleted (kind 5) is found deleted; someone else's kind 5 or a forged one doesn't count", async () => {
  const bob = generateSecretKey()
  const post = note({ content: "look https://media.example/a.png" })
  const del = (sk, tags, at = 200) => finalizeEvent({ kind: 5, created_at: at, content: "", tags }, sk)
  const relaysWith = fives => async (_r, f) => (f.ids ? [post] : f.kinds?.[0] === 5 ? fives : [])
  assert.equal(await readDeleted(post, relaysWith([del(SK, [["e", post.id]])])), true)
  assert.equal(await readDeleted(post, relaysWith([del(bob, [["e", post.id]])])), false, "only the author can delete")
  assert.equal(await readDeleted(post, relaysWith([{ ...del(SK, [["e", ID]]), tags: [["e", post.id]] }])), false, "forged")
  assert.equal(await readDeleted(post, relaysWith([])), false)

  assert.equal(await guestPostDeleted(post.id, [], relaysWith([del(SK, [["e", post.id]])])), true, "the guest view asks before it draws")
  assert.equal(await guestPostDeleted(post.id, [], relaysWith([])), false)
  assert.equal(await guestPostDeleted(ID, [], async () => []), false, "no relay has it: not deleted, the thread screen says not found")
  assert.equal(await guestPostDeleted(post.id, [], async (_r, f) => (f.ids ? [{ ...post, content: "forged" }] : [del(SK, [["e", post.id]])])), false,
    "a forged copy of the post is not the post")

  const article = finalizeEvent({ kind: 30023, created_at: 100, content: "# hi", tags: [["d", "a"]] }, SK)
  const addr = `30023:${PK}:a`
  const withA = fives => async (_r, f) => (f["#a"] ? fives : [])
  assert.equal(await readDeleted(article, withA([del(SK, [["a", addr]], 150)])), true, "an address deletion after the post")
  assert.equal(await readDeleted(article, withA([del(SK, [["a", addr]], 50)])), false, "one older than this version doesn't cover it")
})
