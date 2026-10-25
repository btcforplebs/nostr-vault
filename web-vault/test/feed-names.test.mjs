// Names in the Feed for people it doesn't follow: the start of a thread a follow replied to, and the note inside a
// bare repost. Tron's live run (RESEARCH/NV_WEB_VAULT_SLOW_FEED_READS_TRON.md, 2026-10-25) had 15 of 110 names stay a
// bare npub in Threaded View after 40 s. Test keys and a mocked pool only: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { h, render } from "preact"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

// Just enough DOM for preact to render into and for the test to read text back (as in thread-repost.test.mjs).
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = { setProperty() {} }; this.attributes = {} }
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
Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })

const { pool } = await import("../src/net/pool.js")
const { setQuoteSource } = await import("../src/net/quotes.js")
const { fetchProfiles, getProfile, namesIn } = await import("../src/net/profiles.js")
const { noteAuthors } = await import("../src/net/feeds.js")
const { FeedRows, rootFetcher } = await import("../src/components/FeedRows.jsx")
const { CondensedNote } = await import("../src/components/CondensedNote.jsx")

const now = Math.floor(Date.now() / 1000)
const note = (sk, content, tags = [], at = now - 60) => finalizeEvent({ kind: 1, created_at: at, tags, content }, sk)
const profile = (sk, name) => finalizeEvent({ kind: 0, created_at: now - 999, tags: [], content: JSON.stringify({ name }) }, sk)
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 300; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }

// Haven: empty outbox, a /feed that stores and answers kind 0 by author.
function fakeVault() {
  const stored = []
  const answer = async f => stored.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey)) && (!f.ids || f.ids.includes(e.id)))
  return { stored, outbox: { query: async () => [] }, feed: { query: answer, event: async e => { stored.push(e); return { ok: true } } } }
}
// Relays that hold `events`: answer ids and kind-0-by-author filters.
function relaysHold(t, events) {
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(pool, "querySync", async (_urls, f) => events.filter(e =>
    (!f.ids || f.ids.includes(e.id)) && (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))))
}

test("Threaded View names the stranger whose post started a thread a follow replied to", async t => {
  const stranger = generateSecretKey(), follow = generateSecretKey()
  const root = note(stranger, "the stranger's post", [], now - 600)
  const reply = note(follow, "a follow's reply", [["e", root.id, "", "root"], ["p", root.pubkey]])
  relaysHold(t, [root, profile(stranger, "Stranger Danger"), profile(follow, "Fran Follow")])
  const vault = fakeVault()
  setQuoteSource({ vault, relays: [] })
  await fetchProfiles(vault, [reply.pubkey], []) // what FeedScreen asks for a page: its authors
  const el = document.createElement("div")
  render(h(FeedRows, { notes: [reply], layout: "threaded", fetchRoots: rootFetcher(vault, []) }), el)
  await until(() => /the stranger's post/.test(el.textContent), "the fetched root on screen")
  await until(() => /Stranger Danger/.test(el.textContent), "the root author's name")
  assert.equal(getProfile(root.pubkey).name, "Stranger Danger")
  assert.ok(vault.stored.some(e => e.kind === 0 && e.pubkey === root.pubkey), "Following keeps the name in Haven")
  render(null, el)
})

test("a stranger feed's roots are named in memory only", async t => {
  const stranger = generateSecretKey()
  const root = note(stranger, "a root")
  relaysHold(t, [root, profile(stranger, "Memory Only")])
  const vault = fakeVault()
  const found = await rootFetcher(vault, [], { save: false })([root.id])
  assert.equal(found.get(root.id)?.id, root.id)
  await until(() => getProfile(root.pubkey)?.name === "Memory Only", "the root author's name")
  assert.equal(vault.stored.length, 0, "nothing written to Haven")
})

test("Compact View names the author of the note inside a bare repost", async t => {
  const author = generateSecretKey(), reposter = generateSecretKey()
  const inner = note(author, "the reposted words")
  const bare = finalizeEvent({ kind: 6, created_at: now, tags: [["e", inner.id], ["p", inner.pubkey]], content: "" }, reposter)
  relaysHold(t, [inner, profile(author, "Bare Author"), profile(reposter, "Rae Poster")])
  const vault = fakeVault()
  setQuoteSource({ vault, relays: ["wss://r.example"] }) // a quote with no relay to ask gives up at once
  const el = document.createElement("div")
  render(h(CondensedNote, { event: bare, card: true }), el)
  await until(() => /the reposted words/.test(el.textContent), "the reposted note")
  await until(() => /Bare Author/.test(el.textContent), "its author's name")
  render(null, el)
})

test("a page's authors include who a bare repost is of (its p tag)", () => {
  const a = getPublicKey(generateSecretKey()), b = getPublicKey(generateSecretKey()), c = getPublicKey(generateSecretKey())
  const bare = { kind: 6, pubkey: a, content: "", tags: [["e", "f".repeat(64)], ["p", b]] }
  const full = { kind: 6, pubkey: a, content: JSON.stringify({ pubkey: c }), tags: [["p", b]] }
  assert.deepEqual(noteAuthors([bare]), [a, b])
  assert.deepEqual(noteAuthors([full]), [a, c], "the embedded note's author wins over the tag")
  assert.deepEqual(noteAuthors([{ kind: 6, pubkey: a, content: "", tags: [] }]), [a])
})

// Profile writes: 1,047 follows were written one round trip at a time behind the slowest relay's answer.
test("each relay's names are drawn as they land; a relay that never answers doesn't hold them", async () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const vault = fakeVault()
  const query = async ([url]) => (url === "wss://fast.example" ? [profile(sk, "Quick")] : new Promise(() => {}))
  const work = fetchProfiles(vault, [pk], ["wss://fast.example"], { query })
  await namesIn([pk], work)
  assert.equal(getProfile(pk).name, "Quick")
  await until(() => vault.stored.some(e => e.pubkey === pk), "the name written to Haven")
})

test("a second ask for someone being fetched waits on that fetch instead of asking again", async () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const vault = fakeVault()
  let asked = 0, answer
  const held = new Promise(r => { answer = r })
  const query = async () => { asked++; await held; return [profile(sk, "Waited")] }
  const first = fetchProfiles(vault, [pk], [], { query })
  let secondDone = false
  const second = fetchProfiles(vault, [pk], [], { query: async () => { throw new Error("asked twice") } }).then(() => { secondDone = true })
  await tick(10)
  assert.equal(secondDone, false, "the second ask waits for the first's answer")
  const relaysAsked = asked
  answer()
  await Promise.all([first, second])
  assert.equal(getProfile(pk).name, "Waited")
  assert.equal(asked, relaysAsked, "no second round of asks")
})

test("a relay's answer is written to Haven in one batch, and a copy another relay sent is not written again", async () => {
  const sks = Array.from({ length: 30 }, () => generateSecretKey()), pks = sks.map(getPublicKey)
  const evs = sks.map((sk, i) => profile(sk, `n${i}`))
  let live = 0, most = 0
  const vault = fakeVault()
  const put = vault.feed.event
  vault.feed.event = async e => { live++; most = Math.max(most, live); await tick(1); live--; return put(e) }
  await fetchProfiles(vault, pks, ["wss://a.example", "wss://b.example"], { query: async () => evs })
  assert.ok(most > 1, `writes overlap (most at once: ${most})`)
  assert.equal(vault.stored.length, 30, "each name written once")
})
