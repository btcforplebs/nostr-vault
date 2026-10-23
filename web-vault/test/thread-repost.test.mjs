// A reposted note's thread offline: /feed holds the kind 6, not the note inside it, so readThread() takes the root
// from the repost's embedded copy. Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, finalizeEvent, verifyEvent, verifiedSymbol } from "nostr-tools/pure"
import { h, render } from "preact"
import { buildThread, flattenThread, readThread, repostedNote, verifiedCopy } from "../src/net/thread.js"
import { pool } from "../src/net/pool.js"

// Node can't load .jsx: compile it with Vite's Oxc transform, as in storage-note.test.mjs.
registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { threadStart, ThreadScreen } = await import("../src/screens/ThreadScreen.jsx")

const now = Math.floor(Date.now() / 1000)
const author = generateSecretKey(), reposter = generateSecretKey(), replier = generateSecretKey()
const original = finalizeEvent({ kind: 1, created_at: now - 60, tags: [], content: "the reposted note" }, author)
const repost = (inner, sk = reposter) =>
  finalizeEvent({ kind: 6, created_at: now, tags: [["e", inner.id], ["p", inner.pubkey]], content: JSON.stringify(inner) }, sk)
const reply = finalizeEvent({ kind: 1, created_at: now - 30, tags: [["e", original.id, "", "root"]], content: "a reply" }, replier)

// Haven /feed's query, enough for ids, kinds and #e.
const feedOf = events => ({
  feed: {
    query: async f => events.filter(e =>
      (!f.ids || f.ids.includes(e.id)) && (!f.kinds || f.kinds.includes(e.kind)) &&
      (!f["#e"] || e.tags.some(t => t[0] === "e" && f["#e"].includes(t[1])))),
  },
})

test("offline, a reposted note's thread opens from the repost's embedded note", async () => {
  const t = buildThread(original.id, await readThread(feedOf([repost(original), reply]), original.id))
  assert.equal(t.root?.id, original.id)
  assert.equal(t.root.content, "the reposted note")
  assert.deepEqual(t.replies.map(r => r.event.id), [reply.id])
})

test("the stored note wins over a repost's copy", async () => {
  const vault = feedOf([original, repost(original)])
  const evs = await readThread(vault, original.id)
  assert.equal(evs.filter(e => e.id === original.id).length, 1)
  assert.equal(evs[0], original)
})

test("an embedded note that isn't the one asked for, or isn't signed by its author, is not used", async () => {
  const forged = { ...original, content: "words the author never signed" }
  assert.equal(await repostedNote(feedOf([repost(forged)]), original.id), null)
  const other = finalizeEvent({ kind: 1, created_at: now, tags: [], content: "another note" }, author)
  const mislabelled = finalizeEvent({ kind: 6, created_at: now, tags: [["e", original.id]], content: JSON.stringify(other) }, reposter)
  assert.equal(await repostedNote(feedOf([mislabelled]), original.id), null)
  const garbage = finalizeEvent({ kind: 6, created_at: now, tags: [["e", original.id]], content: "not json" }, reposter)
  assert.equal(await repostedNote(feedOf([garbage]), original.id), null)
  assert.equal(buildThread(original.id, await readThread(feedOf([repost(forged)]), original.id)).root, null)
})

// ThreadScreen's opening read, then what it renders: readThread plus the carried note.
const open = async (vault, id) => {
  const { rootId, extra } = await threadStart(vault, id)
  return { rootId, thread: buildThread(rootId, [...await readThread(vault, rootId), ...extra]) }
}
const replyToOriginal = finalizeEvent({ kind: 1, created_at: now - 20, tags: [["e", original.id, "", "root"]], content: "a reposted reply" }, replier)

test("offline, a repost of a reply opens under its real root when /feed has that root", async () => {
  const { rootId, thread } = await open(feedOf([original, repost(replyToOriginal)]), replyToOriginal.id)
  assert.equal(rootId, original.id)
  assert.equal(thread.root?.id, original.id)
  assert.deepEqual(flattenThread(thread.replies).map(r => r.event.id), [replyToOriginal.id])
})

test("offline, a repost of a reply whose root isn't stored opens under the reply itself", async () => {
  const { rootId, thread } = await open(feedOf([repost(replyToOriginal)]), replyToOriginal.id)
  assert.equal(rootId, replyToOriginal.id)
  assert.equal(thread.root?.id, replyToOriginal.id)
})

test("a stored note still opens under its root, stored or not, and an unknown id under itself", async () => {
  assert.equal((await threadStart(feedOf([reply]), reply.id)).rootId, original.id)
  assert.deepEqual(await threadStart(feedOf([]), original.id), { rootId: original.id, extra: [] })
})

test("a note carrying a \"verified\" flag is still checked against its signature", () => {
  const forged = { ...original, content: "words the author never signed", [verifiedSymbol]: true }
  assert.equal(verifyEvent({ ...forged }), true) // the trap: a spread keeps the flag, so verifyEvent takes its word
  assert.equal(verifiedCopy(forged), null)
  assert.deepEqual(verifiedCopy({ ...original, [verifiedSymbol]: true, extra: 1 }), { ...original })
})

test("a malformed embedded note is skipped, never thrown", async () => {
  for (const bad of [null, 5, "x", { ...original, tags: 5 }, { ...original, tags: [[{}]] }, { ...original, created_at: {} }])
    assert.equal(verifiedCopy(bad), null)
  const malformed = { ...original, tags: { length: 1 } }
  assert.equal(await repostedNote(feedOf([repost(malformed)]), original.id), null)
})

// Just enough DOM for preact to render ThreadScreen into and for the test to read text back.
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) {
    n.parentNode?.removeChild(n)
    const i = ref ? this.childNodes.indexOf(ref) : -1
    i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n)
    n.parentNode = this
    return n
  }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener() {}
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}

globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 200; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }

test("a late opening read for the previous note doesn't swap in its carried note", async t => {
  Object.defineProperty(globalThis.navigator, "onLine", { value: false, configurable: true })
  // A reposted note, then a reposted reply whose root is stored: only the carried copy puts that reply in its thread.
  // The first note's opening read is held until the second thread is reading its replies, so the stale run lands
  // between the second's threadStart and its render.
  const first = finalizeEvent({ kind: 1, created_at: now - 50, tags: [], content: "the first note" }, author)
  const events = [repost(first), original, repost(replyToOriginal)]
  const held = []
  const hold = f => new Promise(resolve => held.push({ f, go: () => resolve(feedOf(events).feed.query(f)) }))
  const isFirstOpen = f => f.ids?.[0] === first.id && !held.some(x => x.f === f)
  const isSecondReplies = f => f.kinds?.[0] === 1 && f["#e"]?.[0] === original.id
  let holding = true
  const vault = { feed: { query: f => holding && (isFirstOpen(f) || isSecondReplies(f)) ? hold(f) : feedOf(events).feed.query(f) } }
  const ctx = { vault, account: { relays: { read: [] } } }
  // The focused note's reaction summary asks relays even offline: answer it empty so nothing reaches the network.
  const querySync = pool.querySync
  pool.querySync = async () => []
  t.after(() => { pool.querySync = querySync })

  const el = document.createElement("div")
  render(h(ThreadScreen, { ctx, id: first.id }), el)
  await until(() => held.length === 1, "the first note's opening read")
  render(h(ThreadScreen, { ctx, id: replyToOriginal.id }), el)
  await until(() => held.length === 2, "the second note's reply read")
  holding = false
  held[0].go() // the first note's run finishes late
  await new Promise(r => setTimeout(r, 20))
  held[1].go()
  await until(() => /the reposted note/.test(el.textContent), "the second thread on screen")
  assert.match(el.textContent, /a reposted reply/)
  assert.doesNotMatch(el.textContent, /No replies yet\./)
  render(null, el)
})

test("a network sync still running for the previous note doesn't take over the next thread", async () => {
  Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
  // Every relay query waits until the test answers it, so which sync finishes when is set by the test, not by timing.
  const held = []
  let holding = true
  const querySync = pool.querySync
  pool.querySync = async (_, f) => holding ? new Promise(resolve => held.push({ f, answer: () => resolve([]) })) : []
  const el = document.createElement("div")
  try {
    // First a stored note, then a reposted reply whose root is stored: the second thread shows that reply only from
    // its carried copy, so the first sync landing late (its root, this thread's extra) would drop it.
    const first = finalizeEvent({ kind: 1, created_at: now - 50, tags: [], content: "the first note" }, author)
    const events = [first, original, repost(replyToOriginal)]
    const ctx = { vault: { feed: { query: feedOf(events).feed.query, event: async () => ({ ok: true }) } }, account: { relays: { read: [] } } }

    render(h(ThreadScreen, { ctx, id: first.id }), el)
    await until(() => held.some(q => q.f["#e"]?.[0] === first.id && !q.f.kinds?.includes(7)), "the first note's sync asking relays for replies")
    render(h(ThreadScreen, { ctx, id: replyToOriginal.id }), el)
    await until(() => /a reposted reply/.test(el.textContent), "the second thread on screen")

    // The first sync's relays answer now. Everything it would still do after that (store, setRootId, reload from the
    // in-memory /feed) is promise work, so one timer turn runs all of it; the second turn lets preact render it.
    held.find(q => q.f["#e"]?.[0] === first.id && !q.f.kinds?.includes(7)).answer()
    await tick()
    await tick()
    assert.match(el.textContent, /the reposted note/)
    assert.match(el.textContent, /a reposted reply/)
    assert.doesNotMatch(el.textContent, /the first note/)
  } finally {
    // Unmount, then let the second sync run out against empty relays, so nothing reaches the real network.
    render(null, el)
    holding = false
    held.forEach(q => q.answer())
    await tick()
    pool.querySync = querySync
  }
})
