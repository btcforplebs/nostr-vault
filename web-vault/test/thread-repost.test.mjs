// A reposted note's thread offline: /feed holds the kind 6, not the note inside it, so readThread() takes the root
// from the repost's embedded copy. Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { buildThread, readThread, repostedNote } from "../src/net/thread.js"

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
