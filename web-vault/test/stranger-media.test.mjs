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
const { ActivityRow, ActivityThumb } = await import("../src/screens/VaultScreen.jsx")
const { activityRows } = await import("../src/net/vault-lists.js")
const { MediaImage } = await import("../src/components/MediaImage.jsx")
const { TapImage } = await import("../src/components/NoteText.jsx")
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
  if (node.type === ActivityThumb) find(ActivityThumb(node.props), type, out) // a Vault row's picture
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

test("NoteText: with images off, a video link stays a link, so a stranger's server sees nothing", () => {
  const url = "https://tracker.example/v.mp4"
  const off = NoteText({ content: url, depth: 1, images: false })
  assert.equal(find(off, "video").length, 0, "no <video> when images are off")
  assert.deepEqual(find(off, "a").map(a => a.props.href), [url])
})

// Sweep 2026-11-10 §3: a stranger's mention carrying an imeta picture drew <MediaImage>, which sets <img src> at once.
test("Vault activity: a stranger's picture thumbnails wait for a tap; a follow's and your own load", () => {
  const ME = "1".repeat(64), PIX = "https://tracker.example/pixel.png", MINE = "https://media.example/mine.png"
  const mention = who => ({ id: who.slice(0, 2).padEnd(64, "0"), kind: 1, pubkey: who, created_at: 1000, content: `hi ${PIX}`,
    tags: [["p", ME], ["imeta", `url ${PIX}`, "m image/png"]] })
  const myNote = { id: "9".repeat(64), kind: 1, pubkey: ME, created_at: 900, content: MINE, tags: [] }
  const like = { id: "8".repeat(64), kind: 7, pubkey: STRANGER, created_at: 1001, content: "+", tags: [["e", myNote.id], ["p", ME]] }
  const rows = activityRows([mention(STRANGER), mention(FRIEND), like], ME, { mine: [myNote] })
  const trust = pk => pk === ME || pk === FRIEND
  const draw = row => { const t = ActivityRow({ row, trusted: trust }); return { img: find(t, MediaImage), tap: find(t, TapImage), raw: find(t, "img") } }

  const stranger = draw(rows.find(r => r.kind === "mention" && r.actors[0] === STRANGER))
  assert.equal(stranger.img.length, 0, "no MediaImage (it would set src) for a stranger's picture")
  assert.equal(stranger.raw.length, 0, "no <img> for a stranger's picture")
  assert.deepEqual(stranger.tap.map(t => t.props.src), [PIX], "it waits behind Show image")

  const friend = draw(rows.find(r => r.kind === "mention" && r.actors[0] === FRIEND))
  assert.deepEqual(friend.img.map(i => i.props.item.url), [PIX], "a follow's picture loads")

  const liked = draw(rows.find(r => r.kind === "like"))
  assert.deepEqual(liked.img.map(i => i.props.item.url), [MINE], "your own note's picture loads under a stranger's like")
})

test("Vault activity: a stranger's .fips picture stays with MediaImage, whose mesh gate holds it", () => {
  const FIPS = "http://npub1qqxjlqqqlr465efdc65pdqjzlm0tew3f3ca34u6p4yh6yn0edu6s79wkc6.fips/" + "e4".repeat(32)
  const tree = ActivityThumb({ url: FIPS, by: STRANGER, load: false })
  assert.equal(tree.type, MediaImage)
})
