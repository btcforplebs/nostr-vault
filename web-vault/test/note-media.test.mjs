// A full note card's media, as iOS NostrEvent.mediaURLs: text media links, then NIP-92 imeta urls not already there.
import test from "node:test"
import assert from "node:assert/strict"
import { imetaMedia, imetaType, isWebPageHost, noteMedia } from "../src/net/note-media.js"

const blob = "https://blossom.example/" + "ab".repeat(32)

test("text media first, in order, then imeta-only media; a url in both shows once", () => {
  const tags = [["imeta", "url https://x.example/b.gif", "m image/gif"], ["imeta", "url https://x.example/a.png"], ["imeta", `url ${blob}`, "m video/mp4"]]
  const links = ["https://x.example/page", "https://x.example/a.png", "https://x.example/v.webm", "https://x.example/a.png"]
  assert.deepEqual(noteMedia(links, tags).map(m => [m.url, m.type]), [
    ["https://x.example/a.png", "image"], ["https://x.example/v.webm", "video"], ["https://x.example/b.gif", "image"], [blob, "video"],
  ])
})

test("no tags: just the text's media links", () => {
  assert.deepEqual(noteMedia(["https://x.example/a.jpg", "https://x.example/"], undefined), [{ url: "https://x.example/a.jpg", type: "image" }])
  assert.deepEqual(noteMedia([], []), [])
})

test("an extensionless text link is media when imeta describes it, and keeps its place in the text order", () => {
  const tags = [["imeta", `url ${blob}`, "m image/jpeg"]]
  assert.deepEqual(noteMedia(["https://x.example/v.mp4", blob], tags).map(m => m.url), ["https://x.example/v.mp4", blob])
  assert.deepEqual(noteMedia([blob], []), [], "without imeta it stays a link")
})

test("imeta type: extension first, then the mime, then an image unless the host is a web page", () => {
  assert.equal(imetaType("https://x.example/a.mov", "image/png"), "video", "the extension decides")
  assert.equal(imetaType("https://x.example/song.mp3"), "", "audio isn't drawn as a picture")
  assert.equal(imetaType("https://x.example/page.html", "image/png"), "", "a file of another kind")
  assert.equal(imetaType(blob, "video/quicktime"), "video")
  assert.equal(imetaType(blob, "audio/mpeg"), "")
  assert.equal(imetaType(blob), "image", "an extensionless upload announces itself by imeta")
  assert.equal(imetaType("https://njump.me/" + "ab".repeat(32)), "", "a web client's page")
  assert.equal(imetaType("https://www.primal.net/e/" + "ab".repeat(32)), "")
})

test("web page hosts, www. or not; a Blossom host on the same domain is not one", () => {
  assert.equal(isWebPageHost("https://www.Primal.net/x"), true)
  assert.equal(isWebPageHost("https://blossom.primal.net/x"), false)
  assert.equal(isWebPageHost("not a url"), false)
})

test("imeta fields: url must be http(s); dim gives the size; the first tag for a url wins; junk is skipped", () => {
  const m = imetaMedia([
    ["imeta", "url https://x.example/a.png", "dim 640x480"],
    ["imeta", "url https://x.example/a.png", "dim 1x1"],
    ["imeta", "url javascript:alert(1)"],
    ["imeta", "m image/png"],
    ["imeta"],
    ["e", "url https://x.example/b.png"],
    ["imeta", "url https://x.example/c.jpg", "dim wide"],
  ])
  assert.deepEqual([...m.values()], [{ url: "https://x.example/a.png", type: "image", width: 640, height: 480 }, { url: "https://x.example/c.jpg", type: "image" }])
})
