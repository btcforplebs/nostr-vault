// Blocks: the kind 10000 mute list, read from Haven's outbox and the network, and what it hides on each screen.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import {
  pTags, isNip04, decrypterFor, privateBlocks, readBlockList, refreshBlockList, loadBlocks, getBlocks, onBlocks,
  isBlockedNote, visibleNotes, visiblePeople, visibleRows, visibleReplies,
} from "../src/net/blocks.js"
import { groupNotifications } from "../src/net/notifications.js"

const sk = generateSecretKey()
const ME = getPublicKey(sk)
const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64), D = "d".repeat(64)

// A Haven route as far as blocks.js uses it: query by kind/author, and event() keeping the newest replaceable one.
function fakeVault(seed = []) {
  const evs = [...seed]
  const outbox = {
    stored: evs,
    query: async f => evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey)),
    event: async ev => { if (evs.some(e => e.id === ev.id)) return { ok: false, message: "duplicate: have it" }; evs.push(ev); return { ok: true, message: "" } },
  }
  return { outbox }
}
const list = (tags, content = "", created_at = 100) => finalizeEvent({ kind: 10000, created_at, tags, content }, sk)

test("public blocks are the valid p tags, lowercased, once each", () => {
  assert.deepEqual(pTags([["p", A], ["p", A.toUpperCase()], ["p", "short"], ["e", B], ["t", "nsfw"], ["p", C, "wss://x"]]), [A, C])
  assert.deepEqual(pTags(undefined), [])
  assert.deepEqual(pTags([null, "p", ["p"]]), [])
})

test("NIP-04 ciphertext is told apart from NIP-44 by its iv", () => {
  assert.equal(isNip04("abc?iv=def"), true)
  assert.equal(isNip04("AgAAAAAA"), false)
})

test("a private part is decrypted with the matching scheme from the extension", async () => {
  const key = nip44.getConversationKey(sk, ME)
  const c44 = nip44.encrypt(JSON.stringify([["p", B], ["t", "x"]]), key)
  const c04 = nip04.encrypt(sk, ME, JSON.stringify([["p", D]]))
  const calls = []
  const ext = {
    nip44: { decrypt: async (pk, c) => { calls.push(["nip44", pk]); return nip44.decrypt(c, key) } },
    nip04: { decrypt: async (pk, c) => { calls.push(["nip04", pk]); return nip04.decrypt(sk, pk, c) } },
  }
  const opener = await decrypterFor({ method: "nip07", pubkey: ME }, { ext })
  assert.deepEqual(await privateBlocks(list([], c44), opener), { pubkeys: [B], note: "" })
  assert.deepEqual(await privateBlocks(list([], c04), opener), { pubkeys: [D], note: "" })
  assert.deepEqual(calls, [["nip44", ME], ["nip04", ME]])
})

test("when the private part can't be read, the note says why and the public part still applies", async () => {
  const bunker = await decrypterFor({ method: "nip46", pubkey: ME })
  assert.match(bunker.reason, /bunker isn't connected/)
  assert.deepEqual(await privateBlocks(list([], "AgAAAA"), bunker), { pubkeys: [], note: bunker.reason })
  const no44 = await decrypterFor({ method: "nip07", pubkey: ME }, { ext: { nip04: { decrypt: async () => "[]" } } })
  assert.match((await privateBlocks(list([], "AgAAAA"), no44)).note, /NIP44/)
  const refused = await decrypterFor({ method: "nip07", pubkey: ME }, { ext: { nip44: { decrypt: async () => { throw new Error("user said no") } } } })
  assert.equal((await privateBlocks(list([], "AgAAAA"), refused)).note, "user said no")
  assert.deepEqual(await privateBlocks(list([["p", A]], ""), bunker), { pubkeys: [], note: "" }, "no private part, nothing to explain")
})

test("the list is read from Haven's outbox, newest first, and the network's copy is stored there", async () => {
  const old = list([["p", A]], "", 100)
  const vault = fakeVault([old])
  assert.equal((await readBlockList(vault, ME)).id, old.id)
  const fresh = list([["p", A], ["p", B]], "", 200)
  const someoneElse = finalizeEvent({ kind: 10000, created_at: 300, tags: [["p", C]], content: "" }, generateSecretKey())
  const got = await refreshBlockList(vault, ME, ["wss://r"], { query: async () => [fresh, someoneElse, old] })
  assert.equal(got.id, fresh.id)
  assert.ok(vault.outbox.stored.includes(fresh))
  assert.ok(!vault.outbox.stored.includes(someoneElse), "only the user's own list is stored")
})

test("loadBlocks shows Haven's copy, then the newer network one, once per account", async () => {
  const vault = fakeVault([list([["p", A]], "", 100)])
  const fresh = list([["p", A], ["p", B]], "", 200)
  let queries = 0, changes = 0
  const off = onBlocks(() => changes++)
  const ctx = { vault, session: { method: "nip46", pubkey: ME } }
  const opener = { reason: "test" }
  const p = loadBlocks(ctx, ["wss://r"], { opener, query: async () => { queries++; return [fresh] } })
  assert.equal(loadBlocks(ctx, ["wss://r"], { opener }), p, "a second screen shares the first load")
  await p
  off()
  assert.deepEqual([...getBlocks().blocked].sort(), [A, B])
  assert.equal(getBlocks().pubkey, ME)
  assert.equal(queries, 1)
  assert.ok(changes >= 2)
})

test("blocked notes and reposts of them are hidden; others stay", () => {
  const blocked = new Set([A])
  const mine = { id: "1", kind: 1, pubkey: C }
  const theirs = { id: "2", kind: 1, pubkey: A }
  const repost = { id: "3", kind: 6, pubkey: C, content: JSON.stringify({ pubkey: A, kind: 1 }) }
  const badRepost = { id: "4", kind: 6, pubkey: C, content: "not json" }
  assert.equal(isBlockedNote(theirs, blocked), true)
  assert.equal(isBlockedNote(repost, blocked), true)
  assert.deepEqual(visibleNotes([mine, theirs, repost, badRepost], blocked).map(e => e.id), ["1", "4"])
  const none = [mine, theirs]
  assert.equal(visibleNotes(none, new Set()), none, "nothing blocked, same array")
})

test("search people drop blocked pubkeys", () => {
  assert.deepEqual(visiblePeople([A, B, C], new Set([B])), [A, C])
})

test("notification rows lose blocked people and are regrouped", () => {
  const note = "e".repeat(64)
  const ev = (id, kind, pubkey, at, tags = []) => ({ id, kind, pubkey, created_at: at, content: kind === 7 ? "+" : "hi", tags: [["p", ME], ...tags] })
  const raw = [
    ev("r1", 7, A, 10, [["e", note]]),
    ev("r2", 7, B, 11, [["e", note]]),
    ev("m1", 1, A, 12),
    ev("m2", 1, C, 13),
  ]
  const rows = groupNotifications(raw, ME)
  const shown = visibleRows(rows, new Set([A]), ME)
  assert.deepEqual(shown.map(r => [r.type, r.who]), [["mention", [C]], ["reaction", [B]]])
  assert.equal(visibleRows(rows, new Set(), ME), rows)
})

test("a thread drops blocked replies but keeps their unblocked replies in their place", () => {
  const n = (id, pubkey, children = []) => ({ event: { id, kind: 1, pubkey }, children })
  const tree = [n("1", C, [n("2", A, [n("3", B), n("4", A)])]), n("5", A)]
  const shown = visibleReplies(tree, new Set([A]))
  assert.deepEqual(shown, [n("1", C, [n("3", B)])])
})
