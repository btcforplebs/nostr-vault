// Notifications and the Vault lists draw what strangers send (replies, likes, zaps, follows, highlights): their
// avatar and inline images load only for a follow or the user, so a stranger's server can't learn the user's IP
// and read time from the list drawing. Rows are rendered as plain vnodes; nothing is fetched.
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
const { Row, Faces } = await import("../src/screens/NotificationsScreen.jsx")
const { ActivityRow } = await import("../src/screens/VaultScreen.jsx")
const { Avatar } = await import("../src/components/Avatar.jsx")
const { NoteText } = await import("../src/components/NoteText.jsx")

const FRIEND = "f".repeat(64), STRANGER = "5".repeat(64)
const trusted = pk => pk === FRIEND

/** Every vnode of `type` in the tree. */
function find(node, type, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (node.type === type) out.push(node)
  if (node.type === Faces) find(Faces(node.props), type, out) // the row's stacked faces
  find(node.props?.children, type, out)
  return out
}

const reply = who => ({ id: "r", type: "reply", who: [who], noteId: null, sats: 0, created_at: 1000,
  events: [{ id: "e", kind: 1, pubkey: who, content: "look https://tracker.example/p.png", tags: [], created_at: 1000 }] })

test("Notifications: a stranger's avatar and inline images wait; a follow's load", () => {
  for (const [who, ok] of [[STRANGER, false], [FRIEND, true]]) {
    const tree = Row({ row: reply(who), trusted })
    assert.equal(find(tree, Avatar)[0].props.load, ok, `avatar for ${ok ? "follow" : "stranger"}`)
    assert.equal(find(tree, NoteText)[0].props.images, ok, `images for ${ok ? "follow" : "stranger"}`)
  }
})

test("Notifications: in a row of several, each face loads only for a follow", () => {
  const tree = Row({ row: { ...reply(STRANGER), type: "reaction", who: [STRANGER, FRIEND, "6".repeat(64)] }, trusted })
  assert.deepEqual(find(tree, Avatar).map(a => a.props.load), [false, true, false])
})

test("Notifications: with no trust given, nothing a sender names loads", () => {
  const tree = Row({ row: reply(FRIEND) })
  assert.equal(find(tree, Avatar)[0].props.load, false)
})

test("Vault activity: a stranger's avatar and reply images wait; a follow's load", () => {
  const row = who => ({ id: "a", kind: "reply", actors: [who], created_at: 1000, openId: null, preview: "https://tracker.example/p.png", emojis: [], sats: 0, images: [] })
  for (const [who, ok] of [[STRANGER, false], [FRIEND, true]]) {
    const tree = ActivityRow({ row: row(who), trusted })
    assert.equal(find(tree, Avatar)[0].props.load, ok)
    assert.equal(find(tree, NoteText)[0].props.images, ok)
  }
})
