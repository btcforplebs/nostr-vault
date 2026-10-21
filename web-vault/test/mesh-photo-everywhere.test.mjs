// Every place the web app draws a note's photo goes through MediaImage, so a photo whose Blossom server lost it (or a
// NIP-F1 .fips link) still comes from the author's mesh vault: Media grid (Media feed, profile), Compact thumbs,
// reply previews (ParentPreview, by source), Vault media grid and activity thumbnails. Before, only the note card and
// lightbox did, and the rest showed a broken image. Vnodes only: nothing is fetched.
import test from "node:test"
import assert from "node:assert/strict"
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
const { imageItem } = await import("../src/net/note-media.js")
const { mediaUrls, mediaTiles } = await import("../src/net/media.js")
const { mediaFor, activityRows } = await import("../src/net/vault-lists.js")
const { MediaImage } = await import("../src/components/MediaImage.jsx")
const { MediaGrid } = await import("../src/components/MediaGrid.jsx")
const { Thumb } = await import("../src/components/CondensedNote.jsx")
const { ActivityRow } = await import("../src/screens/VaultScreen.jsx")

const HASH = "e40a76df2e154784d6d159ddca808c295eb514274b965d53e1f27575a6c8ee0e"
const OTHER = "ab".repeat(32)
const ME = "1".repeat(64), AUTHOR = "2".repeat(64)
const PHOTO = `https://media.example/${HASH}.png`
const FIPS = `http://npub1qqxjlqqqlr465efdc65pdqjzlm0tew3f3ca34u6p4yh6yn0edu6s79wkc6.fips/${HASH}`
const imeta = (url, x) => ["imeta", `url ${url}`, "m image/png", ...(x ? [`x ${x}`] : []), "dim 1024x768"]
const note = (tags, content = PHOTO, pubkey = AUTHOR) => ({ id: "a".padEnd(64, "0"), kind: 1, pubkey, created_at: 10, content, tags })

function find(node, type, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (node.type === type) out.push(node)
  find(node.props?.children, type, out)
  return out
}

test("imageItem: the imeta entry, else the hash a Blossom path names; a .fips link carries its own", () => {
  assert.deepEqual(imageItem(PHOTO, [imeta(PHOTO, OTHER)]), { url: PHOTO, type: "image", width: 1024, height: 768, x: OTHER }, "imeta x wins")
  assert.equal(imageItem(PHOTO, [imeta(PHOTO)]).x, HASH, "imeta with no x: the path's")
  assert.equal(imageItem(PHOTO, []).width, undefined)
  assert.equal(imageItem(PHOTO).x, HASH, "no tags at all")
  assert.equal(imageItem("https://media.example/photo.png").x, undefined, "not a Blossom path")
  assert.equal(imageItem(`https://media.example/${HASH}/thumb.png`).x, undefined, "the hash must be the last part")
  assert.equal(imageItem(FIPS).x, undefined, "fipsRef reads it")
})

test("mediaUrls keeps a NIP-F1 photo link (as an image tile) and still drops any other .fips link", () => {
  const n = note([], `${FIPS} http://npub1qqxjlqqqlr465efdc65pdqjzlm0tew3f3ca34u6p4yh6yn0edu6s79wkc6.fips/clip.mp4 ${PHOTO}`)
  assert.deepEqual(mediaUrls(n), [FIPS, PHOTO])
  assert.equal(mediaTiles([note([], FIPS)])[0].type, "image")
})

test("Media grid: each photo tile is a MediaImage with the note's imeta hash and author", () => {
  const n = note([imeta(PHOTO, HASH)])
  const [tile] = MediaGrid({ tiles: mediaTiles([n]) }).props.children
  const [img] = find(tile, MediaImage)
  assert.ok(img, "MediaImage, not a plain <img>")
  assert.equal(img.props.author, AUTHOR)
  assert.equal(img.props.item.x, HASH)
})

test("Compact thumb: MediaImage with the note's author; a video is still the play mark", () => {
  const n = note([imeta(PHOTO, HASH)])
  const [img] = find(Thumb({ url: PHOTO, note: n, more: 0 }), MediaImage)
  assert.equal(img.props.author, AUTHOR)
  assert.equal(img.props.item.x, HASH)
  assert.equal(typeof img.props.onError, "function", "the thumb still hides a photo nothing can reach")
  assert.equal(find(Thumb({ url: "https://media.example/v.mp4", note: n, more: 0 }), MediaImage).length, 0)
})

test("Reply preview draws its photo with MediaImage, a .fips link included", () => {
  const src = readFileSync(fileURLToPath(new URL("../src/components/ParentPreview.jsx", import.meta.url)), "utf8")
  assert.match(src, /<MediaImage item=\{imageItem\(media\[0\], ev\.tags\)\} author=\{ev\.pubkey\}/)
  assert.doesNotMatch(src, /<img /)
})

test("Vault: the media grid and activity thumbnails use MediaImage, with whose note the photo is from", () => {
  const mine = note([imeta(PHOTO, HASH)], PHOTO, ME)
  assert.equal(mediaFor([mine])[0].item.x, HASH)
  const reply = { ...note([imeta(PHOTO, HASH), ["p", ME], ["e", "f".padEnd(64, "0")]], `hi ${PHOTO}`, AUTHOR), id: "c".padEnd(64, "0") }
  const like = { ...note([["e", mine.id], ["p", ME]], "+", AUTHOR), kind: 7, id: "d".padEnd(64, "0") }
  const rows = activityRows([reply, like], ME, { mine: [mine] })
  for (const [kind, by] of [["reply", AUTHOR], ["like", ME]]) {
    const row = rows.find(r => r.kind === kind)
    assert.equal(row.imagesBy, by, kind)
    const [img] = find(ActivityRow({ row, trusted: () => true }), MediaImage)
    assert.equal(img.props.author, by, kind)
    assert.equal(img.props.item.x, HASH, kind)
  }
})
