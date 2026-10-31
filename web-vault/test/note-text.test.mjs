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
const { NoteText, Mention, TapImage } = await import("../src/components/NoteText.jsx")
const { QuotedNote } = await import("../src/components/QuotedNote.jsx")
const { NoteMedia } = await import("../src/components/NoteMedia.jsx")

// The rendered parts: strings stay strings, elements become { type, ...props }.
function parts(content) {
  const children = [NoteText({ content }).props.children].flat(Infinity)
  return children
    .filter(c => c !== "" && c !== false)
    .map(c => (typeof c === "string" ? c : { type: c.type, ...c.props }))
}

test("in a DM, video links stay links, nostr:npub stays short text, and images wait for a tap unless trusted", () => {
  const npub = npubEncode("ab".repeat(32))
  const url = "https://x.example/v.mp4"
  const els = [NoteText({ content: `${url} nostr:${npub} https://x.example/p.png`, dm: true }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
  assert.deepEqual(els.map(e => e.type), ["a", "span", TapImage], "a stranger's image waits for a tap: no tracking pixel")
  const trusted = [NoteText({ content: "https://x.example/p.png", dm: true, images: true }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
  assert.equal(trusted[0].type, "img", "a follow's image shows")
  assert.equal(trusted[0].props.referrerpolicy, "no-referrer")
  assert.equal(els[0].props.href, url, "a link, no <video> preload")
  assert.equal(els[1].type, "span", "no Mention component, so no profile fetch"); assert.match(els[1].props.children, /^npub1/)
  // Outside a DM the same text gets a video player and a Mention.
  const note = [NoteText({ content: `${url} nostr:${npub}` }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
  assert.deepEqual(note.map(e => e.type), [Mention, NoteMedia], "the video goes under the text (NoteMedia)")
  assert.deepEqual(note[1].props.items, [{ url, type: "video" }])
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

// Media leave the text and go under it as NoteMedia items, as iOS FeedNoteRow (NostrContentFormatter strips them).
const mediaOf = out => out.find(p => p.type === NoteMedia)?.items

test("image links become NoteMedia images, out of the text", () => {
  for (const ext of ["png", "jpg", "jpeg", "gif", "webp", "avif", "PNG", "JPG"]) {
    const url = `https://cdn.example.com/pic.${ext}`
    const out = parts(url)
    assert.equal(out.length, 1, ext)
    assert.deepEqual(mediaOf(out), [{ url, type: "image" }], ext)
  }
})

test("an image link with a query string is still an image", () => {
  assert.deepEqual(mediaOf(parts("https://cdn.example.com/pic.jpg?w=600&h=400")), [{ url: "https://cdn.example.com/pic.jpg?w=600&h=400", type: "image" }])
})

test("video links become NoteMedia videos", () => {
  for (const ext of ["mp4", "webm", "mov", "m4v", "MP4"]) {
    const url = `https://cdn.example.com/clip.${ext}`
    assert.deepEqual(mediaOf(parts(url)), [{ url, type: "video" }], ext)
  }
})

test("an extension in the middle of a path is not media", () => {
  assert.equal(parts("https://example.com/pic.png/view")[0].type, "a")
  assert.equal(parts("https://example.com/file.svg")[0].type, "a")
})

test("links and text keep their order; media go after the text, and the whitespace they leave at the ends is trimmed", () => {
  const out = parts("a https://x.com/1.png b https://y.com c\n\nhttps://x.com/2.mp4\n")
  assert.deepEqual(out.map(p => (typeof p === "string" ? p : p.type)), ["a  b ", "a", " c", NoteMedia])
  assert.deepEqual(mediaOf(out).map(m => m.url), ["https://x.com/1.png", "https://x.com/2.mp4"])
})

test("imeta media show too, once: a url already in the text isn't repeated", () => {
  const tags = [["imeta", "url https://x.com/1.png", "m image/png"], ["imeta", "url https://b.example/" + "c".repeat(64), "m video/mp4", "dim 1920x1080"]]
  const children = [NoteText({ content: "hi https://x.com/1.png", tags }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
  assert.equal(children.length, 1)
  assert.deepEqual(children[0].props.items, [{ url: "https://x.com/1.png", type: "image" }, { url: "https://b.example/" + "c".repeat(64), type: "video", width: 1920, height: 1080 }])
})

test("with images off (a stranger in Notifications) an image still waits for a tap, in place", () => {
  const els = [NoteText({ content: "a https://x.com/1.png b", images: false }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
  assert.deepEqual(els.map(e => e.type), [TapImage])
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
  const out = parts("look https://x.com/pic.png.")
  assert.deepEqual(out[0], "look .")
  assert.deepEqual(mediaOf(out), [{ url: "https://x.com/pic.png", type: "image" }])
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
  const inner = [NoteText({ content: `nostr:${note}`, depth: 1 }).props.children].flat(Infinity).filter(c => c !== "" && c !== false)
  assert.equal(inner[0].type, "span")
  assert.equal(inner[0].props.class, "mention")
  assert.equal(inner[0].props.children, note.slice(0, 12) + "…")
  const hex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
  assert.equal([NoteText({ content: `nostr:${hex}`, depth: 1 }).props.children].flat(Infinity).filter(c => c !== "" && c !== false)[0].type, Mention)
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

test("a .fips link left in the text is plain text: no <img>, <video>, <a> or link card", async () => {
  const { cardLinks } = await import("../src/components/NoteText.jsx")
  const img = "http://box.fips/" + "c".repeat(64) + ".jpg", vid = "https://box.fips./v.mp4", page = "https://box.fips/page"
  for (const props of [{ dm: true, images: true }, { dm: true }, { images: false }]) {
    const els = [NoteText({ content: `${img} ${vid} ${page}`, ...props }).props.children].flat(Infinity).filter(c => c && typeof c !== "string")
    assert.deepEqual(els.map(e => e.type), ["span", "span", "span"], JSON.stringify(props))
    assert.deepEqual(els.map(e => e.props.children), [img, vid, page])
  }
  assert.deepEqual(cardLinks(["", page, " ", "https://x.example/a", ""]), ["https://x.example/a"])
})

test("a note embedding a live stream: the card is the post, its playlist and picture links and the blank lines go", async () => {
  const { liveRefs, liveQuoteTags } = await import("../src/net/live-note.js")
  const service = "c3".repeat(32)
  const naddr = naddrEncode({ kind: 30311, pubkey: service, identifier: "lot-radio", relays: ["wss://relay.zap.stream"] })
  // Logen's note from Android's old share: title, cover, playlist, naddr, one per line.
  const content = `Live now: The Lot Radio: Love Injection\nhttps://img.example/cover.png\nhttps://x.livepeercdn.studio/hls/abc/index.m3u8\nnostr:${naddr}`
  const loading = [NoteText({ content, streams: [null] }).props.children].flat(Infinity).filter(c => c !== "" && c !== false)
  // Before the event loads the playlist goes, but the cover can't yet be told from a picture of the author's own,
  // so it stays in the media row; once loaded, the stream's own image leaves too.
  assert.deepEqual(loading.map(c => (typeof c === "string" ? c : c.type)), ["Live now: The Lot Radio: Love Injection", QuotedNote, NoteMedia],
    "no stream link, no trailing newline before the card")
  const ev = { kind: 30311, pubkey: service, tags: [["d", "lot-radio"], ["image", "https://img.example/cover.png"], ["streaming", "https://x.livepeercdn.studio/hls/abc/index.m3u8"]] }
  const after = [NoteText({ content, streams: [ev] }).props.children].flat(Infinity).filter(c => c !== "" && c !== false)
  assert.deepEqual(after.map(c => (typeof c === "string" ? c : c.type)), ["Live now: The Lot Radio: Love Injection", QuotedNote])
  // Without streams, NoteText hands off to the component that waits for them.
  assert.notEqual(NoteText({ content }).type, "div")
  // The new share text, and a note quoting a normal post, are untouched.
  const fresh = [NoteText({ content: `Live now: Ann\n\nnostr:${naddr}`, streams: [ev] }).props.children].flat(Infinity).filter(c => c !== "" && c !== false)
  assert.deepEqual(fresh.map(c => (typeof c === "string" ? c : c.type)), ["Live now: Ann", QuotedNote])
  assert.deepEqual(parts("look https://x.example/live/index.m3u8\n\nok"), ["look ", { type: "a", href: "https://x.example/live/index.m3u8", target: "_blank", rel: "noopener noreferrer", children: ["x.example/live/index.m3u8", ""] }, "\n\nok"], "a playlist link with no live card stays")
  // q tags: one per live stream, an naddr of another kind is no stream.
  const article = naddrEncode({ kind: 30023, pubkey: service, identifier: "a" })
  assert.equal(liveRefs(`nostr:${naddr} nostr:${naddr} nostr:${article}`).length, 1)
  assert.deepEqual(liveQuoteTags(`x nostr:${naddr}`), [["q", `30311:${service}:lot-radio`, "wss://relay.zap.stream"]])
})
