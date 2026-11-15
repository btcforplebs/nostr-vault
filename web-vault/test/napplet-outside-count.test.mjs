// Bug run group 8: the Reader napplet's count of replies from outside your web (outside-count.js). The notes never
// reach the napplet; the shell counts them with the same gate every napplet read passes.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents } from "../src/napplet/reader-intents.js"
import { outsideReplies } from "../src/napplet/outside-count.js"

const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const me = key(), friend = key(), stranger = key(), stranger2 = key(), blockedOne = key()
const ROOT = "f".repeat(64)
const reply = (k, text, root = ROOT) => finalizeEvent({ kind: 1, created_at: 1, content: text, tags: [["e", root, "", "root"]] }, k.sk)
const deps = (haven, net, { blocked = new Set(), trust = new Set([me.pk, friend.pk]) } = {}) => ({
  pubkey: me.pk, vaultQuery: async () => haven, netQuery: async () => net, wotGate: async () => ev => trust.has(ev.pubkey),
  blocked: () => blocked, verify: ev => { try { return verifyEvent(JSON.parse(JSON.stringify(ev))) } catch { return false } },
})

test("outsideReplies: counts replies whose authors are outside the web, once each; friends, blocked and forgeries don't count", async () => {
  const s1 = reply(stranger, "a"), s2 = reply(stranger2, "b"), f1 = reply(friend, "c"), b1 = reply(blockedOne, "d")
  const forged = { ...reply(stranger, "e"), content: "changed" }, elsewhere = reply(stranger, "f", "e".repeat(64))
  assert.equal(await outsideReplies(ROOT, deps([s1, f1], [s1, s2, b1, forged, elsewhere], { blocked: new Set([blockedOne.pk]) })), 2)
})

test("outsideReplies: no web means only your own pass, so everyone else counts; bad ids and failures give 0", async () => {
  const d = deps([], [reply(friend, "x"), reply(me, "mine")])
  d.wotGate = async () => { throw new Error("no web") }
  assert.equal(await outsideReplies(ROOT, d), 1)
  assert.equal(await outsideReplies("nope", deps([], [])), 0)
  const broken = deps([], []); broken.vaultQuery = async () => { throw new Error("x") }; broken.netQuery = async () => { throw new Error("y") }
  assert.equal(await outsideReplies(ROOT, broken), 0)
})

test("thread/outside: Reader only, a note id, a whole-number count", async () => {
  const bus = createBus(), asked = []
  readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, outside: async id => { asked.push(id); return id === ROOT ? 3 : -1 } })
  const reader = { dTag: "nv-reader", send: () => {} }
  const ask = (who, id) => bus.invoke(who, { archetype: "thread", action: "outside", payload: { id } })
  assert.deepEqual((await ask(reader, ROOT)).data, { count: 3 })
  assert.deepEqual((await ask(reader, "e".repeat(64))).data, { count: 0 })
  assert.equal((await ask(reader, "x")).ok, false)
  assert.equal((await ask({ dTag: "other", send: () => {} }, ROOT)).ok, false)
  assert.deepEqual(asked, [ROOT, "e".repeat(64)])
})
