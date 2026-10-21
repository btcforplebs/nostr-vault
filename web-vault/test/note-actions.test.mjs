// Note actions: the tags a like, repost, reply and quote carry (as the iPhone app builds them), and a like or repost
// reading as sent only once it is signed and a relay took it. Throwaway keys and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { decode } from "nostr-tools/nip19"
import { pool } from "../src/net/pool.js"
import { publishNote } from "../src/net/sync.js"
import {
  REACTION, act, actionState, actionTarget, composeTarget, deleteNote, deletionTemplate, findNote, gateIds, isDeleted, loadDeletions,
  loadSent, publishAction, quoteOf, reactionOf, reactionTemplate, replyTags, repostTemplate, shareLink, unlike,
} from "../src/net/actions.js"

const HEX = /^[0-9a-f]{64}$/
const now = Math.floor(Date.now() / 1000)
const me = generateSecretKey(), author = generateSecretKey(), other = generateSecretKey()
const pk = sk => getPublicKey(sk)
// Each note distinct: the action state is kept per note id across tests.
let n0 = 0
const note = (tags = [], content = `note ${++n0}`, sk = author) => finalizeEvent({ kind: 1, created_at: now - 60, tags, content }, sk)
const plain = ev => JSON.parse(JSON.stringify(ev)) // without nostr-tools' hidden "verified" flag

// A signer holding a throwaway key, an outbox that keeps what it is given, and relays stubbed per test.
function ctxFor({ sk = me, write = ["wss://relay.example.com"] } = {}) {
  const kept = []
  return {
    kept,
    session: { pubkey: pk(me) },
    signer: { signEvent: async t => finalizeEvent(t, sk) },
    account: { relays: { read: write, write } },
    vault: {
      outbox: {
        event: async ev => { kept.push(ev); return { ok: true, message: "" } },
        query: async f => kept.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey) && (!f["#e"] || e.tags.some(t => t[0] === "e" && f["#e"].includes(t[1])))),
      },
      feed: { query: async () => [] },
    },
  }
}
const relaysSay = (t, answer) => {
  const sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push({ urls, ev }); return urls.map(answer) })
  globalThis.location = { hostname: "vault.example.com", hash: "" }
  t.after(() => { delete globalThis.location })
  return sent
}

test("a like is a kind 7 with the iPhone's reaction and e, p and k tags", () => {
  const n = note()
  const t = reactionTemplate(n)
  assert.equal(t.kind, 7)
  assert.equal(t.content, REACTION)
  assert.deepEqual(t.tags, [["e", n.id, ""], ["p", n.pubkey], ["k", "1"]])
})

test("a repost is a kind 6 carrying the note", () => {
  const n = note()
  const t = repostTemplate(n)
  assert.equal(t.kind, 6)
  assert.deepEqual(t.tags, [["e", n.id, ""], ["p", n.pubkey]])
  assert.deepEqual(JSON.parse(t.content), plain(n))
})

test("a reply to a root note: one root e tag with the author, then the author's p", () => {
  const n = note()
  assert.deepEqual(replyTags(n), [["e", n.id, "", "root", n.pubkey], ["p", n.pubkey]])
})

test("a reply to a reply: the thread's root, the parent as reply, and everyone tagged once", () => {
  const root = note()
  const parent = note([["e", root.id, "", "root", root.pubkey], ["p", root.pubkey], ["p", pk(author)], ["p", pk(other)]], "a reply", author)
  assert.deepEqual(replyTags(parent), [
    ["e", root.id, "", "root", root.pubkey],
    ["e", parent.id, "", "reply", parent.pubkey],
    ["p", parent.pubkey], ["p", pk(other)],
  ])
})

test("old positional tags: the first e is the root; a mention-only e doesn't make a note a reply", () => {
  const root = note(), mid = note([], "mid")
  const positional = note([["e", root.id], ["e", mid.id]], "positional reply", other)
  assert.deepEqual(replyTags(positional).slice(0, 2), [["e", root.id, "", "root"], ["e", positional.id, "", "reply", pk(other)]])
  const quoting = note([["e", root.id, "", "mention"]], "only mentions", other)
  assert.deepEqual(replyTags(quoting)[0], ["e", quoting.id, "", "root", pk(other)])
})

test("a quote appends a nevent for the note and tags it with q and p", () => {
  const n = note()
  const { content, tags } = quoteOf(n, "look at this")
  const [text, ref] = content.split("\nnostr:")
  assert.equal(text, "look at this")
  const d = decode(ref)
  assert.equal(d.type, "nevent")
  assert.equal(d.data.id, n.id)
  assert.equal(d.data.author, n.pubkey)
  assert.deepEqual(tags, [["q", n.id, "", n.pubkey], ["p", n.pubkey]])
})

test("publishNote signs the tags it is given", async t => {
  relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  const { event } = await publishNote(c.vault, c.signer, c.session.pubkey, "my reply", c.account.relays.write, replyTags(n))
  assert.deepEqual(event.tags, replyTags(n))
  assert.ok(verifyEvent(event))
})

test("a repost card's actions act on the note inside it, only when that note's signature checks", () => {
  const n = note()
  const repost = finalizeEvent(repostTemplate(n), other)
  assert.deepEqual(plain(actionTarget(repost)), plain(n))
  const forged = finalizeEvent({ ...repostTemplate({ ...n, content: "never signed" }) }, other)
  assert.equal(actionTarget(forged), null)
  assert.equal(actionTarget(finalizeEvent({ kind: 6, created_at: now, tags: [], content: "not json" }, other)), null)
  assert.equal(actionTarget(finalizeEvent({ kind: 7, created_at: now, tags: [], content: "+" }, other)), null)
})

test("a like is sent once signed and a relay took it, and is kept in the outbox", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  const p = act(c, "like", n)
  assert.equal(actionState(n.id).like, "busy")
  await p
  assert.equal(actionState(n.id).like, "sent")
  assert.equal(sent.length, 1)
  assert.equal(sent[0].ev.kind, 7)
  assert.equal(sent[0].ev.pubkey, pk(me))
  assert.ok(verifyEvent(sent[0].ev))
  assert.deepEqual(c.kept.map(e => e.id), [sent[0].ev.id])
})

test("a second tap on a sent repost does nothing", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  await act(c, "repost", n)
  await act(c, "repost", n)
  assert.equal(sent.length, 1)
})

test("a second tap on a sent like takes it back: a kind 5 for that reaction, with k 7", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  await act(c, "like", n)
  const like = sent[0].ev
  await act(c, "like", n)
  assert.equal(sent.length, 2)
  assert.equal(sent[1].ev.kind, 5)
  assert.deepEqual(sent[1].ev.tags, [["e", like.id], ["k", "7"]])
  assert.equal(actionState(n.id).like, undefined)
  // After a reload the taken-back like no longer reads as sent.
  await loadSent(c, n.id)
  assert.equal(actionState(n.id).like, undefined)
})

test("a picked emoji reacts with it; another emoji swaps it (old kind 7 deleted first); the same one takes it back", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  await act(c, "like", n, "🔥")
  assert.equal(sent[0].ev.kind, 7); assert.equal(sent[0].ev.content, "🔥")
  assert.equal(reactionOf(n.id), "🔥"); assert.equal(actionState(n.id).like, "sent")
  await act(c, "like", n, "😂")
  assert.deepEqual(sent.slice(1).map(s => [s.ev.kind, s.ev.content]), [[5, ""], [7, "😂"]])
  assert.deepEqual(sent[1].ev.tags, [["e", sent[0].ev.id], ["k", "7"]])
  assert.equal(reactionOf(n.id), "😂")
  await act(c, "like", n, "😂")
  assert.equal(sent[3].ev.kind, 5); assert.equal(actionState(n.id).like, undefined); assert.equal(reactionOf(n.id), null)
})

test("tapping your own reaction stored as \"+\" (Damus, Amethyst) takes it back: one kind 5, no new kind 7", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const n = note(), c = ctxFor()
  await publishAction(c, reactionTemplate(n, "+"))
  await loadSent(c, n.id)
  sent.length = 0
  const { pickFor, displayEmoji } = await import("./react-pick.mjs")
  await act(c, "like", n, pickFor(displayEmoji(reactionOf(n.id)), "❤️"))
  assert.deepEqual(sent.map(s => s.ev.kind), [5])
  assert.equal(actionState(n.id).like, undefined)
})

test("after a reload your emoji reads back from the outbox", async t => {
  relaysSay(t, () => Promise.resolve(""))
  const n = note(), c = ctxFor()
  await publishAction(c, reactionTemplate(n, "🤙"))
  await loadSent(c, n.id)
  assert.equal(reactionOf(n.id), "🤙")
})

test("unlike a like this browser never saw: found on the account's relays, then deleted", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), n = note()
  const elsewhere = finalizeEvent(reactionTemplate(n), me), stranger = finalizeEvent(reactionTemplate(n), other)
  t.mock.method(pool, "querySync", async () => [elsewhere, stranger])
  await unlike(c, n)
  assert.deepEqual(sent.map(s => s.ev.tags), [[["e", elsewhere.id], ["k", "7"]]])
})

test("unlike with nothing found says why on the heart, from a tap too", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  t.mock.method(pool, "querySync", async () => [])
  const c = ctxFor(), n = note()
  await assert.rejects(unlike(c, n), /wasn't found/)
  assert.deepEqual(actionState(n.id).like, { error: "Your like wasn't found on your relays", unlike: true })
  assert.equal(sent.length, 0)
  // The tap path doesn't swallow it into the console: the heart carries it, and a tap on it tries again.
  await act(c, "like", n)
  assert.match(actionState(n.id).like.error, /wasn't found/)
  assert.equal(pool.querySync.mock.callCount(), 2)
  assert.equal(sent.length, 0)
})

test("a half-failed unlike doesn't read as liked, and the retry sends only the deletion that failed", async t => {
  let down = false
  const sent = relaysSay(t, () => down ? Promise.reject(new Error("down")) : Promise.resolve(""))
  const c = ctxFor(), n = note()
  const a = finalizeEvent(reactionTemplate(n), me), b = finalizeEvent({ ...reactionTemplate(n), content: "+" }, me)
  t.mock.method(pool, "querySync", async () => [a, b])
  const realPublish = pool.publish
  t.mock.method(pool, "publish", (urls, ev) => { down = sent.length >= 1; return realPublish(urls, ev) })
  await assert.rejects(unlike(c, n), /No relay took it/)
  assert.equal(actionState(n.id).like.unlike, true)
  assert.notEqual(actionState(n.id).like, "sent")
  assert.ok(isDeleted(a.id) && !isDeleted(b.id))
  assert.deepEqual(sent.map(s => s.ev.tags[0][1]), [a.id, b.id])
  // The relays still hand back both reactions; only b's deletion is signed again.
  down = false
  t.mock.method(pool, "publish", (urls, ev) => realPublish(urls, ev))
  await act(c, "like", n)
  assert.deepEqual(sent.map(s => s.ev.tags[0][1]), [a.id, b.id, b.id])
  assert.equal(actionState(n.id).like, undefined)
  assert.ok(isDeleted(b.id))
})

test("deleting your own post: a kind 5 with only its e tag (NoteDeletion.requestTags); hidden at once", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), mine = note([], "mine", me)
  await deleteNote(c, mine)
  assert.deepEqual(sent[0].ev.tags, [["e", mine.id]])
  assert.equal(sent[0].ev.content, "")
  assert.ok(isDeleted(mine.id))
  await assert.rejects(deleteNote(c, note()), /your own/)
  assert.equal(sent.length, 1)
})

test("deletions kept in the outbox hide those posts after a reload", async t => {
  relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor(), id = "b".repeat(64)
  await publishAction(c, deletionTemplate(id, 1))
  assert.equal(isDeleted(id), false)
  await loadDeletions(c)
  assert.ok(isDeleted(id))
})

test("Share and Copy link point at the public nostrvault.app thread page for the note's nevent", () => {
  const n = note()
  const link = shareLink(n)
  assert.match(link, /^https:\/\/nostrvault\.app\/thread\/nevent1/)
  assert.equal(decode(link.split("/thread/")[1]).data.id, n.id)
})

test("no relay took it: the action shows the error and can be tried again", async t => {
  relaysSay(t, () => Promise.reject(new Error("connection failed")))
  const c = ctxFor(), n = note()
  await act(c, "repost", n)
  assert.match(actionState(n.id).repost.error, /No relay took it/)
  assert.equal(c.kept.length, 0) // not kept, or a reload would show it as sent
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.resolve("")))
  await act(c, "repost", n)
  assert.equal(actionState(n.id).repost, "sent")
})

test("a signer that signs as someone else never gets published", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor({ sk: other }), n = note()
  await assert.rejects(publishAction(c, reactionTemplate(n)), /different account/)
  await act(c, "like", n)
  assert.match(actionState(n.id).like.error, /different account/)
  assert.equal(sent.length, 0)
})

test("after a reload, a like and repost already in the outbox read as sent", async t => {
  relaysSay(t, () => Promise.resolve(""))
  const n = note(), c = ctxFor()
  await publishAction(c, reactionTemplate(n))
  await publishAction(c, repostTemplate(n))
  await loadSent(c, n.id)
  assert.deepEqual(actionState(n.id), { like: "sent", repost: "sent" })
})

test("compose's hash: reply and quote take a note id; anything else is a plain new note", () => {
  const id = "a".repeat(64)
  assert.deepEqual(composeTarget(`#/compose?reply=${id}`), { mode: "reply", id })
  assert.deepEqual(composeTarget(`#/compose?quote=${id}`), { mode: "quote", id })
  for (const h of ["#/compose", "#/compose?reply=xyz", `#/compose?zap=${id}`, `#/feed?reply=${id}`]) assert.equal(composeTarget(h), null, h)
})

test("compose finds the note in Haven, signature checked, before asking the network", async t => {
  const n = note()
  t.mock.method(pool, "querySync", async () => { throw new Error("network asked") })
  const c = ctxFor()
  c.vault.feed.query = async f => f.ids.includes(n.id) ? [n] : []
  assert.deepEqual(plain(await findNote(c, n.id)), plain(n))
  c.vault.feed.query = async () => [{ ...n, content: "tampered" }]
  assert.equal(await findNote(c, n.id), null)
})

test("the card and compose load outside Vite (their stylesheet is Vite-only)", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  assert.equal(typeof (await import("../src/components/NoteCard.jsx")).NoteCard, "function")
  assert.equal(typeof (await import("../src/screens/ComposeScreen.jsx")).ComposeScreen, "function")
  assert.ok(HEX.test(pk(me)))
})

test("a card is gated on the note a repost carries too: deleting your post hides reposts of it", () => {
  const mine = note([], "mine", me)
  const rp = finalizeEvent(repostTemplate(mine), other)
  assert.deepEqual(gateIds(rp), [rp.id, mine.id])
  const bare = finalizeEvent({ kind: 6, created_at: now, tags: [["e", mine.id, ""]], content: "" }, other)
  assert.deepEqual(gateIds(bare), [bare.id, mine.id])
  assert.deepEqual(gateIds(mine), [mine.id])
})
