// Live Vault (Logen, 2026-11-04): "zaps show first, other items later, sometimes never". A like or repost of a note of
// yours showed only once that note was among the own events read from Haven, a page that also held your own likes;
// zaps always showed. Now: own notes read without likes, likes/reposts on your notes show before the note is in
// Haven, and the panel reads again as soon as Haven keeps something.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { activityRows, readOwn, onMyNote, OWN_NOTE_KINDS } from "../src/net/vault-lists.js"
import { onSaved, savedOne, throttle } from "../src/net/vault-saved.js"

const mySk = generateSecretKey(), me = getPublicKey(mySk)
const other = "b".repeat(64), liker = "c".repeat(64)
const myNote = finalizeEvent({ kind: 1, created_at: 1000, tags: [], content: "an older note of mine" }, mySk)
const like = (target, author, id = "l1", at = 2000) => ({ id, pubkey: liker, kind: 7, created_at: at, content: "+", tags: [["e", target], ["p", author]] })

test("a like of your note shows before that note is in Haven, by its last p tag", () => {
  const rows = activityRows([like(myNote.id, me)], me, { mine: [] })
  assert.equal(rows.length, 1)
  assert.deepEqual([rows[0].kind, rows[0].openId, rows[0].preview], ["like", myNote.id, ""])
  const filled = activityRows([like(myNote.id, me)], me, { mine: [myNote] })
  assert.equal(filled[0].preview, "an older note of mine", "the text fills in once the note is there")
})

test("a like of someone else's note that only mentions you stays out", () => {
  const ev = { ...like("f".repeat(64), other), tags: [["e", "f".repeat(64)], ["p", me], ["p", other]] }
  assert.equal(onMyNote(ev, me), false)
  assert.deepEqual(activityRows([ev], me, { mine: [] }), [])
})

test("a repost of your note shows too, its text from the note it carries when that note is signed", () => {
  const repost = { id: "r1", pubkey: liker, kind: 6, created_at: 2100, tags: [["e", myNote.id], ["p", me]], content: JSON.stringify(myNote) }
  const [row] = activityRows([repost], me, { mine: [] })
  assert.deepEqual([row.kind, row.preview], ["repost", "an older note of mine"])
  const forged = { ...repost, id: "r2", content: JSON.stringify({ ...myNote, content: "words I never wrote" }) }
  assert.equal(activityRows([forged], me, { mine: [] })[0].preview, "", "an unsigned or altered copy lends nothing")
})

test("zaps keep their own line as before", () => {
  // A zap with no valid request names nobody and stays out, as before: unchanged behaviour.
  assert.deepEqual(activityRows([{ id: "z", pubkey: other, kind: 9735, created_at: 1, tags: [["p", me]], content: "" }], me, { mine: [] }), [])
})

test("the panel reads your own notes without your likes, so a page reaches further back", async () => {
  let asked = null
  const vault = { outbox: { query: async f => { asked = f; return [] } } }
  await readOwn(vault, me, { kinds: OWN_NOTE_KINDS })
  assert.ok(!asked.kinds.includes(7))
  await readOwn(vault, me)
  assert.ok(asked.kinds.includes(7), "the Vault list's own read is unchanged")
  const hook = readFileSync(new URL("../src/desktop/space/useVaultLines.js", import.meta.url), "utf8")
  assert.match(hook, /readOwn\(ctx\.vault, me, \{ kinds: OWN_NOTE_KINDS \}\)/)
})

test("Haven's saves wake the panel, throttled so an import costs one read per gap", async () => {
  const got = []
  const off = onSaved((route, ev) => got.push([route, ev.id]))
  savedOne("/inbox", { id: "x" }); off(); savedOne("/inbox", { id: "y" })
  assert.deepEqual(got, [["/inbox", "x"]])
  let t = 0, runs = 0, pending = null
  const th = throttle(() => runs++, 2000, { now: () => t, set: (f, ms) => (pending = { f, at: t + ms }), clear: () => (pending = null) })
  th.call(); assert.equal(runs, 1, "the first save reads at once")
  for (let i = 0; i < 50; i++) { t += 10; th.call() }
  assert.equal(runs, 1); assert.ok(pending, "the burst waits for the end of the gap")
  t = pending.at; pending.f(); assert.equal(runs, 2, "one more read for the whole burst")
  const vault = readFileSync(new URL("../src/haven/vault.js", import.meta.url), "utf8")
  assert.match(vault, /if \(r\?\.ok\) savedOne\(route, ev\)/, "only an accepted event is news")
})

test("the notes to fetch: like, repost or zap lines with no text yet, each once", async () => {
  const { missingNotes } = await import("../src/desktop/space/useVaultLines.js")
  const lines = [{ kind: "like", openId: "a", preview: "" }, { kind: "reply", openId: "b", preview: "" }, { kind: "like", openId: "c", preview: "hi" }, { kind: "repost", openId: "a", preview: "" }]
  assert.deepEqual(missingNotes(lines, new Set()), ["a"])
  assert.deepEqual(missingNotes(lines, new Set(["a"])), [])
})

test("a like or repost of a note Haven doesn't hold yet only counts from your network, once there is one", () => {
  const trusted = new Set([liker])
  assert.equal(activityRows([like(myNote.id, me)], me, { mine: [], trusted }).length, 1, "from your web")
  const stranger = { ...like(myNote.id, me), id: "l9", pubkey: "d".repeat(64) }
  assert.deepEqual(activityRows([stranger], me, { mine: [], trusted }), [], "from outside: nothing ties it to a note we can see")
  assert.equal(activityRows([stranger], me, { mine: [myNote], trusted }).length, 1, "on a note Haven holds, anyone's like counts, as before")
})
