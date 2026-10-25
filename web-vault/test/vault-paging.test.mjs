// Vault paging (checkpoint 7): the Vault tab reads Haven a page at a time and pages back with `until`, as the phone's
// loadMore does, so an account with more than one page of notes reaches its oldest. Following Backup keeps the list
// a follow replaced and the new one. Fake Haven routes and a fake snapshot store: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { readOwn, readInbound, readOlder, READ_PAGE } from "../src/net/vault-lists.js"
import { keepFollowChange } from "../src/net/follow-backup.js"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { FIRST_ROWS, MORE_ROWS } = await import("../src/components/PagedList.jsx")
const screen = readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")

const ME = "a".repeat(64), THEM = "b".repeat(64)
const id = n => n.toString(16).padStart(64, "0")
// A route answering like Haven: newest first, `until` inclusive, `limit` per read.
const route = evs => ({
  asked: [],
  async query(f) {
    this.asked.push(f)
    return evs.filter(e => (!f.until || e.created_at <= f.until) && (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))
      && (!f["#p"] || e.tags.some(t => t[0] === "p" && f["#p"].includes(t[1]))))
      .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit)
  },
})
const notes = n => Array.from({ length: n }, (_, i) => ({ id: id(i + 1), kind: 1, pubkey: ME, tags: [], content: `n${i}`, created_at: 100000 - i }))
const likes = n => Array.from({ length: n }, (_, i) => ({ id: id(90000 + i), kind: 7, pubkey: THEM, tags: [["p", ME]], content: "+", created_at: 100000 - i }))

test("the first read is one page; paging back with until reaches the oldest note and then stops", async () => {
  const vault = { outbox: route(notes(1200)), inbox: route(likes(30)) }
  let own = await readOwn(vault, ME), inbound = await readInbound(vault, ME)
  assert.equal(own.length, READ_PAGE)
  let more = { own: own.length >= READ_PAGE, inbound: inbound.length >= READ_PAGE }
  assert.deepEqual(more, { own: true, inbound: false })
  let pages = 0
  while (more.own || more.inbound) {
    const r = await readOlder(vault, ME, { own, inbound, more })
    own = [...own, ...r.own]; inbound = [...inbound, ...r.inbound]; more = r.more
    assert.ok(++pages < 10, "paging ends")
  }
  assert.equal(own.length, 1200)
  assert.equal(new Set(own.map(e => e.id)).size, 1200, "no note twice")
  assert.equal(Math.min(...own.map(e => e.created_at)), 100000 - 1199, "the oldest note is reached")
  assert.equal(vault.inbox.asked.length, 1, "a short inbox is never asked again")
})

test("events sharing the cursor's second are kept, not skipped", async () => {
  // 600 notes in 3 seconds: a page ends inside a second, and `until` is inclusive.
  const evs = Array.from({ length: 600 }, (_, i) => ({ id: id(i + 1), kind: 1, pubkey: ME, tags: [], content: "", created_at: 5000 - Math.floor(i / 200) }))
  const vault = { outbox: route(evs), inbox: route([]) }
  let own = await readOwn(vault, ME, { limit: 250 }), more = { own: true, inbound: false }
  for (let i = 0; i < 10 && more.own; i++) { const r = await readOlder(vault, ME, { own, inbound: [], more, limit: 250 }); own = [...own, ...r.own]; more = r.more }
  // The last 200 share one second, so a 250 page from it can't step past them; what fits in one page is never lost.
  assert.ok(own.length >= 450, `got ${own.length}`)
  assert.equal(new Set(own.map(e => e.id)).size, own.length)
})

test("a store with nothing read yet, or a read that fails, ends paging instead of looping", async () => {
  const vault = { outbox: { query: async () => { throw new Error("closed") } }, inbox: route([]) }
  const r = await readOlder(vault, ME, { own: notes(3), inbound: [], more: { own: true, inbound: true } })
  assert.deepEqual(r, { own: [], inbound: [], more: { own: false, inbound: false } })
})

test("rows are drawn 100 at first, then 50 more, as the phone's Vault lists; no list draws all its rows at once", () => {
  assert.equal(FIRST_ROWS, 100)
  assert.equal(MORE_ROWS, 50)
  const list = screen.slice(screen.indexOf("function List("), screen.indexOf("export function ActivityRow"))
  assert.equal((list.match(/paged\(/g) ?? []).length, 8) // the eight lists
  assert.doesNotMatch(list, /\.map\([a-z] => <(NoteCard|ArticleCard|ActivityRow|EngagementRow|HighlightCard)/)
})

test("a follow keeps the list it replaced and the new one in Following Backup", async () => {
  const sk = generateSecretKey(), me = getPublicKey(sk)
  const list = (pks, at) => finalizeEvent({ kind: 3, created_at: at, content: "", tags: pks.map(p => ["p", p]) }, sk)
  const m = new Map()
  const store = { all: async () => [...m.values()].sort((a, b) => b.created_at - a.created_at), put: async s => { m.set(s.id, s) }, remove: async i => { m.delete(i) } }
  const before = list([THEM], 100), after = list([THEM, ME.replace("a", "c")], 101)
  assert.equal(await keepFollowChange(me, before, after, store), true)
  assert.deepEqual((await store.all()).map(s => s.id), [after.id, before.id])
  // No list before (a first follow): only the new one; a store that fails never throws into the follow.
  assert.equal(await keepFollowChange(me, null, list([THEM], 102), store), true)
  assert.equal(m.size, 3)
  const broken = { all: async () => { throw new Error("no idb") }, put: async () => {}, remove: async () => {} }
  assert.equal(await keepFollowChange(me, before, after, broken), false)
})
