// NIP-30 custom emoji on the classic web: :shortcode: drawn as pictures in notes, names and reactions, your sets in
// the picker, and a reaction with one carrying its emoji tag (net/custom-emoji.js, components/CustomEmoji.jsx).
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
const { emojiMap, splitShortcodes, reactionCode, rememberEmoji, reactionEmojiTags, myEmoji, seenEmoji } = await import("../src/net/custom-emoji.js")
const { NoteText } = await import("../src/components/NoteText.jsx")
const { EmojiImg, emojiNodes } = await import("../src/components/CustomEmoji.jsx")
const { displayEmoji } = await import("../src/components/ReactionButton.jsx")
const { reactionTemplate } = await import("../src/net/actions.js")
const { reactionDisplayEmoji, reactionEmojiSummary } = await import("../src/net/notifications.js")

const PK = "a".repeat(64)
const URL1 = "https://img.example/blob.png"

// Every element under a vnode tree (components are not called, so EmojiImg shows as itself).
const flat = n => n == null || typeof n !== "object" ? [] : Array.isArray(n) ? n.flatMap(flat) : [n, ...flat(n.props?.children)]
const pics = tree => flat(tree).filter(e => e.type === EmojiImg).map(e => e.props)

test("emojiMap keeps valid shortcodes with https pictures, the first per code", () => {
  const m = emojiMap([["emoji", "blob", URL1], ["emoji", "blob", "https://other/x.png"], ["emoji", "bad code", URL1], ["emoji", "http", "http://x/y.png"], ["p", PK]])
  assert.deepEqual([...m], [["blob", URL1]])
  assert.equal(emojiMap(undefined).size, 0)
})

test("splitShortcodes splits only codes with a picture", () => {
  const m = new Map([["blob", URL1]])
  assert.deepEqual(splitShortcodes("hi :blob: and :nope: :blob:!", m), ["hi ", "blob", " and :nope: ", "blob", "!"])
  assert.deepEqual(splitShortcodes("12:30:45", m), ["12:30:45"])
  assert.deepEqual(splitShortcodes(":blob:", new Map()), [":blob:"])
})

test("a note's :shortcode: shows as its picture; with images off it stays text", () => {
  const tags = [["emoji", "blob", URL1]]
  const on = NoteText({ content: "hello :blob: world #nostr **:blob:**", tags })
  assert.deepEqual(pics(on), [{ code: "blob", url: URL1 }, { code: "blob", url: URL1 }], "plain, and inside bold")
  assert.ok(flat(on).some(e => e.props?.class === "hashtag"), "hashtags still link")
  assert.deepEqual(pics(NoteText({ content: "hello :blob:", tags, images: false })), [], "pictures wait")
  assert.deepEqual(pics(NoteText({ content: "hello :blob:" })), [], "no emoji tag, no picture")
})

test("a reaction with a shortcode carries the picture; reaction display draws it once known", () => {
  assert.equal(reactionCode(":party_parrot:"), "party_parrot")
  assert.equal(reactionCode("🔥"), null)
  assert.deepEqual(reactionEmojiTags(":unknown_x:"), [])
  assert.equal(reactionDisplayEmoji(":unknown_x:"), "❤️", "no picture: a heart, as the iPhone")
  rememberEmoji([["emoji", "parrot", URL1]])
  assert.equal(seenEmoji().get("parrot"), URL1)
  const t = reactionTemplate({ id: "b".repeat(64), pubkey: PK, kind: 1 }, ":parrot:")
  assert.deepEqual(t.tags.at(-1), ["emoji", "parrot", URL1])
  assert.equal(t.content, ":parrot:")
  assert.equal(reactionTemplate({ id: "b".repeat(64), pubkey: PK, kind: 1 }, "🔥").tags.some(x => x[0] === "emoji"), false)
  assert.equal(displayEmoji(":parrot:"), ":parrot:")
  assert.equal(reactionDisplayEmoji(":parrot:"), ":parrot:")
  assert.equal(reactionEmojiSummary(["🔥", ":parrot:"]), "🔥:parrot:")
  assert.deepEqual(pics(emojiNodes("reacted 🔥:parrot: to your note", seenEmoji())), [{ code: "parrot", url: URL1 }])
})

test("your emoji: the sets your list names, each code once, and your own picture wins for reactions", async () => {
  rememberEmoji([["emoji", "mine", "https://stranger/x.png"]])
  const ctx = { session: { pubkey: "c".repeat(64) } }
  const A = `30030:${PK}:one`, B = `30030:${PK}:two`
  const got = await myEmoji(ctx, {
    read: async () => ({ event: { tags: [["a", A], ["a", B], ["emoji", "loose", URL1]] } }),
    sets: async () => new Map([[A, { title: "One", emoji: [{ code: "mine", url: URL1 }] }], [B, { title: "Two", emoji: [{ code: "mine", url: "https://x/2.png" }, { code: "two", url: URL1 }] }]]),
  })
  assert.deepEqual(got.map(e => [e.code, e.set]), [["mine", "One"], ["two", "Two"]], "loose emoji tags are not listed; first set wins a code")
  rememberEmoji([["emoji", "mine", "https://stranger/y.png"]])
  assert.deepEqual(reactionEmojiTags(":mine:"), [["emoji", "mine", URL1]])
  assert.equal(await myEmoji(ctx, { read: async () => { throw new Error("asked twice") } }), got, "loaded once a session")
})
