// A reposted note's thread offline: /feed holds the kind 6, not the note inside it, so readThread() takes the root
// from the repost's embedded copy. Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { buildThread, flattenThread, readThread, repostedNote } from "../src/net/thread.js"

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
const { threadStart } = await import("../src/screens/ThreadScreen.jsx")

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
