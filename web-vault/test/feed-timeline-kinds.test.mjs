// Comments (1111), pictures (20) and generic reposts (16) in the feed, read as the iPhone reads them
// (GenericRepost.swift, NIP10Thread.isNoteComment, FeedServiceTypes.timelineKinds). Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { h, render } from "preact"
import { FEED_KINDS } from "../src/net/sync.js"
import { timelineShows, isShownRepost, genericRepostInner, repostRef, commentParent, commentParentAuthor, isRepost } from "../src/net/feed-kinds.js"
import { applyFilters, isReply } from "../src/net/feed-filters.js"
import { isBlockedNote } from "../src/net/blocks.js"
import { noteAuthors } from "../src/net/feeds.js"
import { gateIds } from "../src/net/actions.js"

const now = Math.floor(Date.now() / 1000)
const alice = generateSecretKey(), bob = generateSecretKey(), carol = generateSecretKey()
const A = getPublicKey(alice), B = getPublicKey(bob), C = getPublicKey(carol)
const sign = (sk, kind, content = "", tags = []) => finalizeEvent({ kind, created_at: now, tags, content }, sk)
const note = sign(alice, 1, "hello")
const article = sign(alice, 30023, "body", [["d", "post"], ["title", "An Article"]])
const video = sign(alice, 21, "", [["title", "clip"]])
const commentOnNote = sign(bob, 1111, "nice", [["E", note.id, "", A], ["K", "1"], ["P", A], ["e", note.id, "", A], ["k", "1"], ["p", A]])
const commentOnVideo = sign(bob, 1111, "cool", [["E", video.id], ["K", "21"], ["e", video.id], ["k", "21"], ["p", A]])
const picture = sign(alice, 20, "sunset", [["imeta", "url https://img.example/a.jpg", "m image/jpeg"], ["title", "Sunset"]])
const repost16 = (inner, tags = [["e", inner.id], ["p", inner.pubkey], ["k", String(inner.kind)]], content = JSON.stringify(inner)) => sign(bob, 16, content, tags)

test("Following asks the relays for every iPhone timeline kind", () => {
  for (const k of [1, 6, 16, 20, 1068, 1111, 9802, 30023]) assert.ok(FEED_KINDS.includes(k), String(k))
})

test("a comment shows only when it answers a note; it is a reply to its parent's author", () => {
  assert.equal(timelineShows(commentOnNote), true)
  assert.equal(timelineShows(commentOnVideo), false, "comments on videos, articles and the rest are not note threads")
  assert.equal(commentParent(commentOnNote), note.id)
  assert.equal(commentParentAuthor(commentOnNote), A)
  assert.equal(isReply(commentOnNote), true, "the Replies switch hides it, as a kind 1 reply")
  assert.deepEqual(applyFilters([commentOnNote, commentOnVideo, picture], { replies: false, reposts: true }).map(e => e.id), [picture.id])
  assert.deepEqual(applyFilters([commentOnNote, commentOnVideo], { replies: true, reposts: true }).map(e => e.id), [commentOnNote.id])
})

test("a kind 16 shows by its k tag, else by what it embeds, else (bare) yes", () => {
  assert.equal(isShownRepost(repost16(article)), true)
  assert.equal(isShownRepost(repost16(video)), false, "a repost of a video would draw as bare text")
  assert.equal(isShownRepost(repost16(video, [["e", video.id]])), false, "no k tag: the embedded kind decides")
  assert.equal(isShownRepost(repost16(article, [["e", article.id]], "")), true, "bare and untagged")
  assert.equal(isRepost(repost16(article)), true)
  assert.deepEqual(applyFilters([repost16(article), repost16(video), note], { replies: true, reposts: false }).map(e => e.id), [note.id])
})

test("a kind 16's embedded copy is used only when signed; else it points at the e tag or a coordinate", () => {
  assert.equal(genericRepostInner(repost16(article)).id, article.id)
  const forged = { ...article, content: "words never signed" }
  assert.equal(genericRepostInner(repost16(forged, [["e", article.id], ["k", "30023"]])), null)
  assert.equal(genericRepostInner(repost16(video)), null, "a signed copy of a kind no timeline draws")
  assert.deepEqual(repostRef(repost16(article)), { type: "note", id: article.id, relays: [] })
  assert.deepEqual(repostRef(sign(bob, 16, "", [["a", `30023:${A}:post`], ["k", "30023"]])), { type: "addr", kind: 30023, pubkey: A, d: "post", relays: [] })
  assert.equal(repostRef(sign(bob, 16, "", [["a", "junk"]])), null)
})

test("blocks, deletions and the profile prefetch read a kind 16 as a repost and a comment as a reply", () => {
  assert.equal(isBlockedNote(repost16(article), new Set([A])), true, "a follow reposting a blocked person's article")
  assert.equal(isBlockedNote(commentOnNote, new Set([A])), true, "a comment answering a blocked person")
  assert.equal(isBlockedNote(commentOnNote, new Set([C])), false)
  assert.deepEqual(noteAuthors([repost16(article)]), [B, A])
  const r = repost16(article)
  assert.deepEqual(gateIds(r), [r.id, article.id], "deleting the article hides the repost card too")
})

// Just enough DOM for preact to render a NoteCard into and read its text back (as poll-vote-publish.test.mjs).
registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
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
globalThis.document ??= {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
const { NoteCard } = await import("../src/components/NoteCard.jsx")
const draw = ev => { const el = document.createElement("div"); render(h(NoteCard, { event: ev, memoryOnly: true }), el); const text = el.textContent; render(null, el); return text }

test("cards: a kind 16 of an article draws the article; a forged copy is not drawn; a picture shows its caption", () => {
  const text = draw(repost16(article))
  assert.match(text, /reposted/)
  assert.match(text, /An Article/, "drawn as its own kind")
  const forged = draw(repost16({ ...article, tags: [["d", "post"], ["title", "Forged Title"]] }, [["e", article.id], ["k", "30023"]]))
  assert.doesNotMatch(forged, /Forged Title/)
  assert.match(forged, /Loading the reposted note/, "fetched by its e tag instead")
  assert.match(draw(picture), /sunset/)
  assert.match(draw(commentOnNote), /reply to/)
})
