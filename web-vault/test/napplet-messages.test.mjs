// Plan P7: NAP-DM in the shell (dm-dispatch.js) over the classic DM state, and the Messages napplet's pure block.
// DMs are vault-private: an outside napplet gets nothing, whatever it was granted (Logen 2026-11-14); blocked people
// stay out; a napplet sees text only, never a wrap, a seal or a key.
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
  const calls = { read: [], sent: [], asks: [], lookup: [] }, pushed = []
  const listeners = new Set()
  const deps = {
    me: ME, messages: () => messages, blocked: () => new Set([EVE]), trusted: () => new Set([ANN]),
    unread: () => new Map([[ANN, 1], [BOB, 1]]), profile: pk => (pk === ANN ? { name: "Ann", picture: "https://x.example/a.png" } : pk === BOB ? { name: "Bob", picture: "http://x.example/b.png" } : null),
    onChange: cb => { listeners.add(cb); return () => listeners.delete(cb) },
    retry: async id => { calls.retried = id; if (sendFails) throw Object.assign(new Error("Still not delivered"), { failedId: "f2" }); messages.delete(id); const m = msg("w10", ME, ANN, 70, "again"); messages.set("w10", m); return m },
    discard: id => { calls.discarded = id; messages.delete(id) },
    searchName: pk => (pk === ANN ? "Ann Lee" : pk === BOB ? "Bob" : ""), follows: pk => pk === ANN, lookup: pks => calls.lookup.push(pks),
    async send(peer, text, photo) { calls.sent.push(photo ? [peer, text, photo] : [peer, text]); if (sendFails) throw Object.assign(new Error("Not delivered"), { failedId: "pending:9" }); const m = msg("w9", ME, peer, 60, text); messages.set("w9", m); return m },
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

test("dm: an outside napplet with an old private-data grant still reads nothing and can't send; ours isn't asked", async () => {
  const granted = { ...defaultGrant({ domains: ["dm"] }), privateData: true }
  const a = rig({ grant: granted })
  assert.match((await a.ask("dm.send", { recipients: [ANN], content: "one" })).error, /private/)
  assert.deepEqual([a.calls.asks.length, a.calls.sent.length], [0, 0])
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
  assert.match(fs.readFileSync(new URL("../src/napplet/first-party-list.js", import.meta.url), "utf8"), /dTag: MESSAGES_DTAG, [^\n]*domains: \["dm", "resource", "intent", "theme"\]/)
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

test("dm: search is the classic on-device one (names and text); a hit names the matching message; follows ride on rows", async () => {
  const { ask, messages } = rig()
  messages.set("m5", msg("m5", ANN, ANN, 25, "the bee meetup is Friday"))
  const byText = await ask("dm.conversations", { query: "MEETUP" })
  assert.deepEqual(byText.conversations.map(c => [c.id, c.hit?.content, c.last.content]), [[ANN, "the bee meetup is Friday", "sending…"]])
  const byName = await ask("dm.conversations", { query: "lee" })
  assert.deepEqual(byName.conversations.map(c => [c.id, c.hit ?? null]), [[ANN, null]])
  assert.deepEqual((await ask("dm.conversations", { query: "blocked one" })).conversations, []) // a blocked person stays out
  assert.deepEqual((await ask("dm.conversations")).conversations.map(c => [c.id, c.follows]), [[ANN, true], [BOB, false]])
  for (const bad of [{ query: 5 }, { query: "x".repeat(201) }]) assert.ok((await ask("dm.conversations", bad)).error)
})

test("dm: ids gives a brand-new conversation its row (name, face) and looks up who has no name; blocked never", async () => {
  const { ask, calls } = rig()
  const NEW = H("d")
  const r = await ask("dm.conversations", { ids: [ANN, NEW, EVE, NEW] })
  assert.deepEqual(r.conversations.map(c => [c.id, c.participants[0].label ?? null, c.last?.content ?? null, c.updatedAt]), [[ANN, "Ann", "sending…", 50], [NEW, null, null, 0]])
  assert.deepEqual(calls.lookup, [[NEW]])
  for (const bad of [{ ids: "x" }, { ids: ["npub1x"] }, { ids: Array.from({ length: 21 }, (_, i) => H(String(i % 10))) }]) assert.ok((await ask("dm.conversations", bad)).error, JSON.stringify(bad).slice(0, 40))
})

test("dm: a photo (a Blob) goes to the shell's send with its text; only an image, at most 50 MB; photo alone is fine", async () => {
  const { ask, calls } = rig()
  const pic = new Blob([new Uint8Array([1, 2, 3])], { type: "image/jpeg" })
  const ok = await ask("dm.send", { recipients: [ANN], content: "", photo: pic })
  assert.equal(ok.ok, true)
  assert.equal(calls.sent[0][2], pic)
  for (const photo of ["https://x.example/a.jpg", new Blob(["x"], { type: "text/html" }), new Blob([]), { size: 3, type: "image/png" }])
    assert.ok((await ask("dm.send", { recipients: [ANN], content: "hi", photo })).error, String(photo?.type ?? photo))
  const f = rig({ sendFails: true })
  const r = await f.ask("dm.send", { recipients: [ANN], content: "look", photo: pic })
  assert.deepEqual([r.ok, r.message.content], [false, "look\n(photo)"])
})

test("messages napplet: a line that is only a picture link is a photo; previews say Photo", () => {
  const html = fs.readFileSync(new URL("../napplets/messages/index.html", import.meta.url), "utf8")
  const box = {}
  vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { partsOf, previewOf })`, { box, Date })
  const plain = x => JSON.parse(JSON.stringify(x))
  assert.deepEqual(plain(box.partsOf("look\nhttps://b.example/abc.jpg")), [{ text: "look" }, { photo: "https://b.example/abc.jpg" }])
  assert.deepEqual(plain(box.partsOf("see https://b.example/abc.jpg here\nline two")), [{ text: "see https://b.example/abc.jpg here\nline two" }])
  assert.deepEqual(plain(box.partsOf("http://b.example/a.png")), [{ text: "http://b.example/a.png" }]) // https only
  assert.equal(box.previewOf("https://b.example/abc.webp?x=1"), "Photo")
  assert.equal(box.previewOf("hi\n  there\nhttps://b.example/abc.png"), "hi there · Photo")
})

test("messages pane: shell deps get search names, follows and a once-per-person lookup; a photo takes the classic path", () => {
  const pane = fs.readFileSync(new URL("../src/napplet/MessagesPane.jsx", import.meta.url), "utf8")
  assert.match(pane, /searchName, follows: pk => ctxRef\.current\.account\.follows\.includes\(pk\)/)
  assert.match(pane, /const fresh = pks\.filter\(pk => !looked\.current\.has\(pk\)\)/)
  const deps = fs.readFileSync(new URL("../src/napplet/shell-deps.js", import.meta.url), "utf8")
  assert.match(deps, /prepare: async \(\) => \{ const m = await encryptedPhoto\(await \(video \? prepareVideo\(photo\) : preparePhoto\(photo\)\), \{ upload: async f => uploadPhoto\(f, \{ ctx, servers: lockedFileServers\(await mediaServers\(ctx\)\), raw: true \}\) \}\); sentText = m\.shown; return m \}/)
})

test("dm: a failed send hands back its message with the reason on it, never the result's error (the shim would drop it all)", async () => {
  const f = rig({ sendFails: true })
  const r = await f.ask("dm.send", { recipients: [ANN], content: "x" })
  assert.equal(r.error, undefined)
  assert.deepEqual([r.ok, r.message.id, r.message.error], [false, "pending:9", "Not delivered"])
})

test("dm: Try again and Remove work only on your own failed message to that person", async () => {
  const { ask, calls, messages } = rig()
  messages.set("f1", msg("f1", ME, ANN, 65, "lost", { failed: "no relay took it" }))
  messages.set("f9", msg("f9", ME, BOB, 66, "lost too", { failed: "x" }))
  for (const bad of [{ retry: "nope" }, { retry: "m2" }, { retry: "m1" }, { retry: "f9" }, { retry: 5 }])
    assert.ok((await ask("dm.send", { recipients: [ANN], ...bad })).error, JSON.stringify(bad))
  const ok = await ask("dm.send", { recipients: [ANN], conversationId: ANN, content: "", retry: "f1" })
  assert.deepEqual([ok.ok, ok.message.id, ok.message.status, calls.retried], [true, "w10", "sent", "f1"])
  messages.set("f3", msg("f3", ME, ANN, 67, "drop me", { failed: "x" }))
  const gone = await ask("dm.send", { recipients: [ANN], content: "", retry: "f3", discard: true })
  assert.deepEqual([gone.ok, gone.message.removed, calls.discarded, messages.has("f3")], [true, true, "f3", false])
  const f = rig({ sendFails: true })
  f.messages.set("f1", msg("f1", ME, ANN, 65, "lost", { failed: "x" }))
  const again = await f.ask("dm.send", { recipients: [ANN], content: "", retry: "f1" })
  assert.deepEqual([again.ok, again.error, again.message.id, again.message.status, again.message.error], [false, undefined, "f2", "failed", "Still not delivered"])
})

test("messages napplet: a failed bubble of yours has Try again and Remove; one the shell never kept comes back to the box", () => {
  const html = fs.readFileSync(new URL("../napplets/messages/index.html", import.meta.url), "utf8")
  assert.match(html, /if \(m\.status === "failed" && mine && !m\.retrying\)/)
  assert.match(html, /retry: m\.id, \.\.\.\(discard \? \{ discard: true \} : \{\}\)/)
  assert.match(html, /if \(!m\.id \|\| \/\^\(failed\|refused\):\/\.test\(m\.id\)\)/)
})

test("newestMine: what a Try again left, whatever its text", async () => {
  const { newestMine } = await import("../src/napplet/shell-deps-find.js")
  const m = new Map([["a", msg("a", ME, ANN, 1, "old")], ["b", msg("b", ME, ANN, 2, "x\nhttps://p.example/1.jpg")], ["c", msg("c", ME, ANN, 3, "y", { pending: true })], ["d", msg("d", ME, ANN, 4, "z", { failed: "x" })]])
  assert.equal(newestMine(m, ME, ANN, false, new Set(["a"])).id, "b")
  assert.equal(newestMine(m, ME, ANN, true).id, "d")
  assert.equal(newestMine(m, ME, BOB), null)
})

test("dm: a video (a Blob) is sent like a photo, at most 100 MB, and shows as (video) while it goes", async () => {
  const { ask, calls } = rig()
  const clip = new Blob([new Uint8Array([0, 0, 0, 8])], { type: "video/mp4" })
  const ok = await ask("dm.send", { recipients: [ANN], content: "", photo: clip })
  assert.equal(ok.ok, true)
  assert.equal(calls.sent[0][2], clip)
  const f = rig({ sendFails: true })
  const r = await f.ask("dm.send", { recipients: [ANN], content: "watch", photo: clip })
  assert.deepEqual([r.ok, r.message.content], [false, "watch\n(video)"])
})

test("messages napplet: a locked video link is a video; previews say Video", async () => {
  const { fileLink } = await import("../src/net/dm-file.js")
  const html = fs.readFileSync(new URL("../napplets/messages/index.html", import.meta.url), "utf8")
  const box = {}
  vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { partsOf, previewOf })`, { box, Date, atob, TextDecoder, Uint8Array, JSON })
  const plain = x => JSON.parse(JSON.stringify(x))
  const x = "a".repeat(64)
  const video = fileLink(`https://b.example/${x}`, { key: "1".repeat(64), nonce: "2".repeat(24), x, mime: "video/mp4", size: 1234567 })
  const photo = fileLink(`https://b.example/${x}`, { key: "1".repeat(64), nonce: "2".repeat(24), x, mime: "image/png" })
  assert.deepEqual(plain(box.partsOf(`look\n${video}`)), [{ text: "look" }, { video, size: 1234567 }])
  assert.deepEqual(plain(box.partsOf(photo)), [{ photo }])
  assert.equal(box.previewOf(video), "Video")
  assert.equal(box.previewOf(photo), "Photo")
})
