// Plan P7: NAP-DM in the shell (dm-dispatch.js) over the classic DM state, and the Messages napplet's pure block.
// DMs are vault-private: an outside napplet needs the private-data grant to read anything and is asked before each
// send; blocked people stay out; a napplet sees text only, never a wrap, a seal or a key.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { nip19 } from "nostr-tools"
import { dmHandler, MAX_DM_SUBS } from "../src/napplet/dm-dispatch.js"
import { defaultGrant } from "../src/napplet/policy.js"
import { SHELL_DOMAINS } from "../src/napplet/manifest.js"
import { askWords, domainWord } from "../src/napplet/consent-words.js"
import { findMine } from "../src/napplet/shell-deps-find.js"

const H = c => c.repeat(64), ME = H("a"), ANN = H("b"), BOB = H("c"), EVE = H("e")
const msg = (id, from, peer, at, content = id, extra = {}) => ({ id, from, peer, at, content, legacy: false, ...extra })

function rig({ grant = defaultGrant({ firstParty: true }), yes = true, sendFails = false } = {}) {
  const messages = new Map([
    ["m1", msg("m1", ANN, ANN, 10, "hi from Ann")], ["m2", msg("m2", ME, ANN, 20, "hi Ann")],
    ["m3", msg("m3", BOB, BOB, 30, "stranger here")], ["m4", msg("m4", EVE, EVE, 40, "blocked one")],
    ["p1", msg("p1", ME, ANN, 50, "sending…", { pending: true })],
  ])
  const calls = { read: [], sent: [], asks: [] }, pushed = []
  const listeners = new Set()
  const deps = {
    me: ME, messages: () => messages, blocked: () => new Set([EVE]), trusted: () => new Set([ANN]),
    unread: () => new Map([[ANN, 1], [BOB, 1]]), profile: pk => (pk === ANN ? { name: "Ann", picture: "https://x.example/a.png" } : pk === BOB ? { name: "Bob", picture: "http://x.example/b.png" } : null),
    onChange: cb => { listeners.add(cb); return () => listeners.delete(cb) },
    async send(peer, text) { calls.sent.push([peer, text]); if (sendFails) throw Object.assign(new Error("Not delivered"), { failedId: "pending:9" }); const m = msg("w9", ME, peer, 60, text); messages.set("w9", m); return m },
    markRead: list => calls.read.push(list.map(m => m.id)), ask: async q => { calls.asks.push(q); return yes }, randomId: (() => { let i = 0; return () => `r${++i}` })(),
  }
  const h = dmHandler({ grant, who: { title: "Messages" }, deps, push: x => pushed.push(x) })
  const ask = (type, body = {}) => h.handle({ type, id: "1", ...body })
  return { h, ask, calls, pushed, messages, fire: () => listeners.forEach(cb => cb()) }
}

test("dm: conversations newest first, blocked out, strangers marked as requests, https avatars only, no keys or wraps", async () => {
  const { ask } = rig()
  const r = await ask("dm.conversations")
  assert.deepEqual(r.conversations.map(c => [c.id, c.request, c.unread]), [[ANN, false, 1], [BOB, true, 1]])
  assert.equal(r.conversations[0].participants[0].avatar, "https://x.example/a.png")
  assert.equal(r.conversations[1].participants[0].avatar, undefined)
  assert.doesNotMatch(JSON.stringify(r), /"(tags|sig|seal|wrap|pubkey":"[0-9a-f]{64}","created_at)"/) // text only: no event fields
})

test("dm: a conversation oldest first in pages from the newest end; reading it marks it read; blocked shows only yours", async () => {
  const { ask, calls, messages } = rig()
  for (let i = 0; i < 60; i++) messages.set(`x${i}`, msg(`x${i}`, ANN, ANN, 100 + i))
  const first = await ask("dm.messages", { conversationId: ANN, limit: 50 })
  assert.equal(first.messages.length, 50)
  assert.equal(first.messages.at(-1).id, "x59")
  assert.equal(first.cursor, "50")
  const older = await ask("dm.messages", { conversationId: ANN, limit: 50, cursor: first.cursor })
  assert.ok(older.messages.some(m => m.id === "m1") && !older.cursor)
  assert.equal(calls.read.length, 1) // the first page only
  assert.deepEqual((await ask("dm.messages", { conversationId: EVE })).messages, [])
  assert.equal(first.messages.find(m => m.id === "x59").status, "received")
})

test("dm: an outside napplet without the private-data grant reads nothing and can't send", async () => {
  const { ask, calls } = rig({ grant: defaultGrant({ domains: ["dm"] }) })
  const st = await ask("dm.status")
  assert.deepEqual([st.available, st.ownerPubkey], [false, undefined])
  for (const t of ["dm.conversations", "dm.messages", "dm.send", "dm.subscribe"]) assert.match((await ask(t, { conversationId: ANN, recipients: [ANN], content: "x" })).error, /private/)
  assert.equal(calls.sent.length, 0)
})

test("dm: an outside napplet with the grant is asked before every send, shown who and what; no means not sent", async () => {
  const granted = { ...defaultGrant({ domains: ["dm"] }), privateData: true }
  const a = rig({ grant: granted })
  await a.ask("dm.send", { recipients: [ANN], content: "one" })
  await a.ask("dm.send", { recipients: [ANN], content: "two" })
  assert.equal(a.calls.asks.length, 2)
  assert.deepEqual([a.calls.asks[0].what, a.calls.asks[0].detail.to, a.calls.asks[0].detail.content], ["dm-send", ANN, "one"])
  const no = rig({ grant: granted, yes: false })
  const r = await no.ask("dm.send", { recipients: [ANN], content: "nope" })
  assert.deepEqual([r.ok, r.message.status, no.calls.sent.length], [false, "failed", 0])
  const ours = rig()
  await ours.ask("dm.send", { recipients: [ANN], content: "ours" })
  assert.equal(ours.calls.asks.length, 0) // the Messages napplet is the Messages screen
})

test("dm: send is one real recipient with text; never to someone you blocked; a failure says so with the shell's bubble", async () => {
  const { ask, calls } = rig()
  for (const bad of [{ recipients: [] }, { recipients: [ANN, BOB] }, { recipients: ["npub1x"] }, { recipients: [ANN], conversationId: BOB }, { recipients: [ANN], content: "   " }, { recipients: [EVE], content: "hi" }])
    assert.ok((await ask("dm.send", { content: "hi", ...bad })).error, JSON.stringify(bad))
  const ok = await ask("dm.send", { recipients: [ANN], conversationId: ANN, content: "  hello  " })
  assert.deepEqual([ok.ok, ok.message.id, ok.message.content, ok.message.status], [true, "w9", "hello", "sent"])
  assert.deepEqual(calls.sent, [[ANN, "hello"]])
  const f = rig({ sendFails: true })
  const r = await f.ask("dm.send", { recipients: [ANN], content: "x" })
  assert.deepEqual([r.ok, r.message.id, r.message.status], [false, "pending:9", "failed"])
})

test("dm: live messages after subscribing, per conversation, never pending bubbles or a blocked person's; unsubscribe stops it", async () => {
  const r = rig()
  const all = await r.ask("dm.subscribe")
  const one = await r.ask("dm.subscribe", { conversationId: ANN })
  r.fire() // nothing new yet: the snapshot isn't replayed
  assert.equal(r.pushed.length, 0)
  r.messages.set("n1", msg("n1", BOB, BOB, 70)); r.messages.set("n2", msg("n2", ANN, ANN, 71)); r.messages.set("n3", msg("n3", EVE, EVE, 72)); r.messages.set("n4", msg("n4", ME, ANN, 73, "p", { pending: true }))
  r.fire()
  assert.deepEqual(r.pushed.map(p => [p.subscriptionId, p.message.id]), [[all.subscriptionId, "n1"], [all.subscriptionId, "n2"], [one.subscriptionId, "n2"]])
  await r.ask("dm.unsubscribe", { subscriptionId: all.subscriptionId })
  r.messages.set("n5", msg("n5", BOB, BOB, 80)); r.fire()
  assert.equal(r.pushed.length, 3)
  for (let i = 0; i < MAX_DM_SUBS; i++) await r.ask("dm.subscribe")
  assert.match((await r.ask("dm.subscribe")).error, /at most/)
  r.h.close()
})

test("findMine: the shell's own sent (or failed) bubble for this text, never a pending one", () => {
  const m = new Map([["a", msg("a", ME, ANN, 5, "t")], ["b", msg("b", ME, ANN, 9, "t")], ["c", msg("c", ME, ANN, 12, "t", { pending: true })], ["d", msg("d", ME, ANN, 11, "t", { failed: "x" })]])
  assert.equal(findMine(m, ME, ANN, "t").id, "b")
  assert.equal(findMine(m, ME, ANN, "t", true).id, "d")
  assert.equal(findMine(m, ME, BOB, "t"), null)
  // Re-sending the same text: the ids that were there before the send never answer it.
  assert.equal(findMine(m, ME, ANN, "t", false, new Set(["a", "b"])), null)
  m.set("e", msg("e", ME, ANN, 8, "t"))
  assert.equal(findMine(m, ME, ANN, "t", false, new Set(["a", "b", "c", "d"])).id, "e")
})

test("dm is a shell domain with words for the sheets; ours asks for dm, resource, intent, theme only", () => {
  assert.ok(SHELL_DOMAINS.includes("dm"))
  assert.match(domainWord("dm"), /direct messages/)
  const w = askWords("dm-send", { title: "X" }, { to: ANN, name: "Ann", content: "hello" })
  assert.match(w.title, /X wants to send a direct message as you/)
  assert.match(w.body, /^To Ann \(npub1[0-9a-z]{11}…\):\n\nhello$/) // a chosen name never stands alone
  assert.match(askWords("dm-send", {}, { to: ANN, content: "x".repeat(800) }).body, /^To npub1[0-9a-z]{11}…:\n\nx{500}\n\n… and 300 more characters$/)
  assert.match(fs.readFileSync(new URL("../src/napplet/first-party.js", import.meta.url), "utf8"), /dTag: MESSAGES_DTAG, [^\n]*domains: \["dm", "resource", "intent", "theme"\]/)
})

test("messages napplet: npub/nprofile/hex to a pubkey; threads merge once per id, oldest first", () => {
  const html = fs.readFileSync(new URL("../napplets/messages/index.html", import.meta.url), "utf8")
  const box = {}
  vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { pubkeyOf, mergeThread })`, { box, Date })
  assert.equal(box.pubkeyOf(nip19.npubEncode(ANN)), ANN)
  assert.equal(box.pubkeyOf(`nostr:${nip19.nprofileEncode({ pubkey: BOB, relays: ["wss://r.example"] })}`), BOB)
  assert.equal(box.pubkeyOf(` ${EVE} `), EVE)
  assert.equal(box.pubkeyOf(nip19.noteEncode(ANN)), null)
  assert.equal(box.pubkeyOf("npub1xyz"), null)
  const t = JSON.parse(JSON.stringify(box.mergeThread([{ id: "a", createdAt: 5 }], [{ id: "b", createdAt: 1 }, { id: "a", createdAt: 5, status: "sent" }])))
  assert.deepEqual(t.map(m => m.id), ["b", "a"])
})
