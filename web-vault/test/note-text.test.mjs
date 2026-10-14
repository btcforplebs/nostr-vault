// NoteText splits a note into text, links, inline images/video and short nostr: references.
// Node can't load .jsx, so a load hook compiles it with Vite's Oxc transform via rolldown (same JSX settings as vite.config.js).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { decode, npubEncode, nprofileEncode, noteEncode, neventEncode, naddrEncode } from "nostr-tools/nip19"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { NoteText, Mention } = await import("../src/components/NoteText.jsx")
const { QuotedNote } = await import("../src/components/QuotedNote.jsx")

// The rendered parts: strings stay strings, elements become { type, ...props }.
function parts(content) {
  const children = [NoteText({ content }).props.children].flat()
  return children
    .filter(c => c !== "")
    .map(c => (typeof c === "string" ? c : { type: c.type, ...c.props }))
}

test("in a DM, video links stay links and nostr:npub stays short text; images still show", () => {
  const npub = npubEncode("ab".repeat(32))
  const url = "https://x.example/v.mp4"
  const els = [NoteText({ content: `${url} nostr:${npub} https://x.example/p.png`, dm: true }).props.children].flat().filter(c => typeof c !== "string")
  assert.deepEqual(els.map(e => e.type), ["a", "span", "img"])
  assert.equal(els[0].props.href, url, "a link, no <video> preload")
  assert.equal(els[1].type, "span", "no Mention component, so no profile fetch"); assert.match(els[1].props.children, /^npub1/)
  // Outside a DM the same text gets a video player and a Mention.
  const note = [NoteText({ content: `${url} nostr:${npub}` }).props.children].flat().filter(c => typeof c !== "string")
  assert.deepEqual(note.map(e => e.type), ["video", Mention])
})

test("plain text is one text part", () => {
  assert.deepEqual(parts("gm nostr"), ["gm nostr"])
})

test("a link opens in a new tab and shows without its scheme", () => {
  const [before, a, after] = parts("see https://example.com/page now")
  assert.equal(before, "see ")
  assert.equal(after, " now")
  assert.equal(a.type, "a")
  assert.equal(a.href, "https://example.com/page")
  assert.equal(a.target, "_blank")
  assert.equal(a.rel, "noopener noreferrer")
  assert.deepEqual([a.children].flat().join(""), "example.com/page")
})

test("http links are recognised too", () => {
  const [a] = parts("http://example.com")
  assert.equal(a.type, "a")
  assert.equal(a.href, "http://example.com")
})

test("a long https link is cut to 48 characters plus an ellipsis", () => {
  const url = "https://example.com/" + "a".repeat(60)
  const [a] = parts(url)
  assert.equal(a.href, url)
  assert.equal([a.children].flat().join(""), url.slice(8, 56) + "…")
})

test("an https link of exactly 56 characters shows in full, no ellipsis", () => {
  const url = "https://example.com/" + "a".repeat(36)
  assert.equal(url.length, 56)
  assert.equal([parts(url)[0].children].flat().join(""), url.slice(8))
})

test("an http link is cut at the same 48 characters plus an ellipsis", () => {
  const url = "http://example.com/" + "a".repeat(37)
  assert.equal(url.length, 56)
  assert.equal([parts(url)[0].children].flat().join(""), url.slice(7, 55) + "…")
})

test("an http link of 48 characters after the scheme shows in full", () => {
  const url = "http://example.com/" + "a".repeat(36)
  assert.equal([parts(url)[0].children].flat().join(""), url.slice(7))
})

test("image links become lazy inline images", () => {
  for (const ext of ["png", "jpg", "jpeg", "gif", "webp", "avif", "PNG", "JPG"]) {
    const url = `https://cdn.example.com/pic.${ext}`
    const [img] = parts(url)
    assert.equal(img.type, "img", ext)
    assert.equal(img.src, url)
    assert.equal(img.class, "note-media")
    assert.equal(img.loading, "lazy")
    assert.equal(img.alt, "")
  }
})

test("an image link with a query string is still an image", () => {
  const [img] = parts("https://cdn.example.com/pic.jpg?w=600&h=400")
  assert.equal(img.type, "img")
  assert.equal(img.src, "https://cdn.example.com/pic.jpg?w=600&h=400")
})

test("video links become inline video with controls", () => {
  for (const ext of ["mp4", "webm", "mov", "MP4"]) {
    const url = `https://cdn.example.com/clip.${ext}`
    const [video] = parts(url)
    assert.equal(video.type, "video", ext)
    assert.equal(video.src, url)
    assert.equal(video.controls, true)
    assert.equal(video.preload, "metadata")
  }
})

test("an extension in the middle of a path is not media", () => {
  assert.equal(parts("https://example.com/pic.png/view")[0].type, "a")
  assert.equal(parts("https://example.com/file.svg")[0].type, "a")
})

test("several links, images and text keep their order", () => {
  const out = parts("a https://x.com/1.png b https://y.com c")
  assert.deepEqual(out.map(p => (typeof p === "string" ? p : p.type)), ["a ", "img", " b ", "a", " c"])
})

test("links stop at whitespace, quotes and angle brackets", () => {
  for (const [input, href] of [
    ["https://x.com/a\nnext", "https://x.com/a"],
    ['"https://x.com/a"', "https://x.com/a"],
    ["<https://x.com/a>", "https://x.com/a"],
  ]) {
    assert.equal(parts(input).find(p => p.type === "a").href, href, JSON.stringify(input))
  }
})

test("punctuation after a link stays in the text", () => {
  for (const [input, href, tail] of [
    ["see https://x.com/page.", "https://x.com/page", "."],
    ["(https://x.com/page)", "https://x.com/page", ")"],
    ["https://x.com/page, then", "https://x.com/page", ", then"],
    ["wow https://x.com/page!?", "https://x.com/page", "!?"],
    ["https://x.com/page;", "https://x.com/page", ";"],
    ["at https://x.com/page:", "https://x.com/page", ":"],
    ["(see https://x.com/page).", "https://x.com/page", ")."],
  ]) {
    const out = parts(input)
    const i = out.findIndex(p => typeof p !== "string")
    assert.equal(out[i].href, href, JSON.stringify(input))
    assert.equal(out[i + 1], tail, JSON.stringify(input))
  }
})

test("an image link at the end of a sentence is still an image", () => {
  const img = parts("look https://x.com/pic.png.").find(p => typeof p !== "string")
  assert.equal(img.type, "img")
  assert.equal(img.src, "https://x.com/pic.png")
})

test("a link keeps a ) that closes its own (", () => {
  const url = "https://en.wikipedia.org/wiki/Bitcoin_(currency)"
  assert.equal(parts(url)[0].href, url)
  assert.equal(parts(`(${url})`).find(p => typeof p !== "string").href, url)
})

test("punctuation inside a link is kept", () => {
  assert.equal(parts("https://x.com/a.b?q=1,2!x")[0].href, "https://x.com/a.b?q=1,2!x")
})

test("a nostr: npub is a Mention of that pubkey", () => {
  const npub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
  const [before, m] = parts(`hi nostr:${npub}`)
  assert.equal(before, "hi ")
  assert.equal(m.type, Mention)
  assert.equal(m.pubkey, decode(npub).data)
})

test("a nostr: nprofile is a Mention of its pubkey", () => {
  const hex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
  const [m] = parts(`nostr:${nprofileEncode({ pubkey: hex, relays: ["wss://r.example"] })}`)
  assert.equal(m.type, Mention)
  assert.equal(m.pubkey, hex)
})

test("a nostr: hex pubkey is a Mention too", () => {
  const hex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
  const [m] = parts(`nostr:${hex}`)
  assert.equal(m.type, Mention)
  assert.equal(m.pubkey, hex)
})

test("a nostr: note / nevent / naddr becomes a QuotedNote with the parsed reference and a short label", () => {
  const id = "4cd665db9d8ac9b9ab26b2aedb4c6c2a9ed2e21b9c0aa64e7f1ac1cfcc9e5f68"
  const pk = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
  const note = noteEncode(id)
  const [q] = parts(`nostr:${note}`)
  assert.equal(q.type, QuotedNote)
  assert.deepEqual(q.q, { type: "note", id, relays: [] })
  assert.equal(q.short, note.slice(0, 12) + "…")
  assert.equal(q.depth, 0)

  const [qe] = parts(`nostr:${neventEncode({ id, relays: ["wss://r.example"] })}`)
  assert.deepEqual(qe.q, { type: "note", id, relays: ["wss://r.example"] })

  const [qa] = parts(`nostr:${naddrEncode({ kind: 30023, pubkey: pk, identifier: "post-1", relays: [] })}`)
  assert.deepEqual(qa.q, { type: "addr", kind: 30023, pubkey: pk, d: "post-1", relays: [] })
})

test("text around a quote keeps its place", () => {
  const note = noteEncode("4cd665db9d8ac9b9ab26b2aedb4c6c2a9ed2e21b9c0aa64e7f1ac1cfcc9e5f68")
  assert.deepEqual(parts(`look nostr:${note} wow`).map(p => (typeof p === "string" ? p : p.type)), ["look ", QuotedNote, " wow"])
})

test("inside a quoted note (depth 1) a quote stays a short reference, but a mention is still a Mention", () => {
  const note = noteEncode("4cd665db9d8ac9b9ab26b2aedb4c6c2a9ed2e21b9c0aa64e7f1ac1cfcc9e5f68")
  const inner = [NoteText({ content: `nostr:${note}`, depth: 1 }).props.children].flat().filter(c => c !== "")
  assert.equal(inner[0].type, "span")
  assert.equal(inner[0].props.class, "mention")
  assert.equal(inner[0].props.children, note.slice(0, 12) + "…")
  const hex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
  assert.equal([NoteText({ content: `nostr:${hex}`, depth: 1 }).props.children].flat().filter(c => c !== "")[0].type, Mention)
})

test("a nostr: reference that doesn't decode is shown short, as text", () => {
  const [m] = parts("nostr:nonsense123")
  assert.equal(m.type, "span")
  assert.equal(m.class, "mention")
  assert.equal(m.children, "nonsense123…")
})

test("a bare npub without nostr: stays plain text", () => {
  const text = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
  assert.deepEqual(parts(text), [text])
})

test("non-string content is shown as text", () => {
  assert.deepEqual(parts(42), ["42"])
})
