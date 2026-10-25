// The Notifications rows as the iPhone's Vault list draws them (VaultActivityList.swift): where a tap goes, the words
// ("Ann and 2 others liked your note"), and the user's own note shown quietly under a like. Rows are rendered as plain
// vnodes; nothing is fetched or signed.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true } // styles are the browser's
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { Row, Who, rowHref, openId, verb } = await import("../src/screens/NotificationsScreen.jsx")
const { AuthorName } = await import("../src/components/NoteCard.jsx")
const { NoteText } = await import("../src/components/NoteText.jsx")

const ME = "a".repeat(64), ANN = "b".repeat(64), BOB = "c".repeat(64), CAT = "d".repeat(64)
const NOTE = "1".repeat(64), THEIRS = "2".repeat(64)
const row = (type, extra = {}) => ({ id: "r", type, who: [ANN], noteId: null, sats: 0, emoji: "❤️", emojis: [], comment: "", created_at: 1000,
  events: [{ id: THEIRS, kind: 1, pubkey: ANN, content: "their words", tags: [], created_at: 1000 }], ...extra })

function find(node, pred, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, pred, out); return out }
  if (pred(node)) out.push(node)
  // Draws the row's own small pieces (Who, About); the shared components stay as they are.
  if (node.type === Who || node.type?.name === "About") find(node.type(node.props), pred, out)
  find(node.props?.children, pred, out)
  return out
}
/** The text of a vnode tree, with each AuthorName as its pubkey's first letter. */
const text = node => node == null || typeof node === "boolean" ? "" : typeof node !== "object" ? String(node)
  : Array.isArray(node) ? node.map(text).join("")
  : node.type === AuthorName ? node.props.pubkey[0].toUpperCase()
  : typeof node.type === "function" && node.type !== NoteText ? text(node.type(node.props)) : text(node.props?.children)

test("a tap opens their note for a reply, mention, quote, article or highlight", () => {
  for (const type of ["reply", "mention", "quote", "article", "highlight"]) {
    assert.equal(openId(row(type, { noteId: NOTE })), THEIRS, type)
    assert.equal(rowHref(row(type, { noteId: NOTE })), `#/thread/${THEIRS}`, type)
  }
})

test("a tap opens the user's note for a like, repost or zap; a zap on the profile opens the zapper", () => {
  for (const type of ["reaction", "repost", "zap"]) assert.equal(rowHref(row(type, { noteId: NOTE })), `#/thread/${NOTE}`, type)
  assert.equal(rowHref(row("zap")), `#/profile/${ANN}`)
})

test("a tap on a follow opens the person, or the Followers list when several followed that day", () => {
  assert.equal(rowHref(row("follow")), `#/profile/${ANN}`)
  assert.equal(rowHref(row("follow", { who: [ANN, BOB] })), "#/vault/followers")
})

test("a row is a link: a tap moves to its href, a tap on a link inside stays with the link", () => {
  globalThis.location = { hash: "#/notifications" }
  const tree = Row({ row: row("reaction", { noteId: NOTE }) })
  assert.equal(tree.props.role, "link")
  assert.match(tree.props.class, /tappable/)
  tree.props.onClick({ type: "click", button: 0, target: { closest: () => null } })
  assert.equal(location.hash, `#/thread/${NOTE}`)
  location.hash = "#/notifications"
  tree.props.onClick({ type: "click", button: 0, target: { closest: () => ({}) } })
  assert.equal(location.hash, "#/notifications")
})

test("the iPhone's words for each kind", () => {
  assert.equal(verb(row("reply")), "replied to you")
  assert.equal(verb(row("mention")), "mentioned you")
  assert.equal(verb(row("quote")), "quoted your note")
  assert.equal(verb(row("repost", { noteId: NOTE })), "reposted your note")
  assert.equal(verb(row("reaction", { noteId: NOTE, emojis: ["+", ""] })), "liked your note")
  assert.equal(verb(row("reaction", { noteId: NOTE, emojis: ["🔥", "+", "🤙", "😂"] })), "reacted 🔥❤️🤙 to your note")
  assert.equal(verb(row("zap", { noteId: NOTE, sats: 21 })), "zapped your note 21 sats")
  assert.equal(verb(row("zap", { sats: 2100 })), `zapped you ${(2100).toLocaleString()} sats`)
  assert.equal(verb(row("article")), "tagged you in an article")
  assert.equal(verb(row("highlight")), "highlighted you")
  assert.equal(verb(row("follow")), "followed you")
})

test("who: one name, two names, then the first name and N others", () => {
  assert.equal(text(Who({ who: [ANN] })), "B")
  assert.equal(text(Who({ who: [ANN, BOB] })), "B and C")
  assert.equal(text(Who({ who: [ANN, BOB, CAT] })), "B and 2 others")
  assert.equal(text(Who({ who: [] })), "Someone")
})

test("a like shows the user's note as quiet text, without a name; their reply shows their words and no note line", () => {
  const note = { id: NOTE, pubkey: ME, content: "my  note\n text", tags: [] }
  const like = Row({ row: row("reaction", { noteId: NOTE, emojis: ["+"] }), note, me: ME })
  const quiet = find(like, n => /notif-about/.test(n.props?.class ?? ""))
  assert.equal(quiet.length, 1)
  assert.equal(text(quiet[0]), "my note text")
  assert.equal(find(like, n => n.type === AuthorName).length, 1, "only the liker is named")
  assert.equal(find(Row({ row: row("reaction", { noteId: NOTE }), me: ME }), n => /notif-about/.test(n.props?.class ?? "")).length, 0, "nothing while the note loads")
  const reply = Row({ row: row("reply", { noteId: NOTE }), note, me: ME })
  assert.equal(find(reply, n => /notif-about/.test(n.props?.class ?? "")).length, 0)
  assert.equal(find(reply, n => n.type === NoteText)[0].props.content, "their words")
})
