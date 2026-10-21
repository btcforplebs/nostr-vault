// Compose: photo uploads (BUD-02, as the iPhone uploads), @mentions, and what a post and a draft carry.
// Throwaway keys, a stubbed fetch and stubbed relays: nothing is uploaded or published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { decode, npubEncode } from "nostr-tools/nip19"
import { putProfile } from "../src/net/profiles.js"
import { DEFAULT_MEDIA_SERVERS, imetaTag, mediaServers, megabytes, refusal, serverList, sha256Hex, uploadAuthTemplate, uploadPhoto } from "../src/net/upload.js"
import { storeNames } from "../src/haven/vault.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { mentionAt, mentionedPubkeys, rankPeople, resolveMentions, toNostr, uniqueToken } = await import("../src/components/MentionPicker.jsx")
const { buildPost, draftKey, draftOf, isMedia, isVideo } = await import("../src/screens/ComposeScreen.jsx")

const me = generateSecretKey(), other = generateSecretKey()
const pk = sk => getPublicKey(sk)
const ctxFor = (sk = me) => ({
  session: { pubkey: pk(me) },
  signer: { signEvent: async t => finalizeEvent(t, sk) },
  account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] }, follows: [] },
  vault: { outbox: { query: async () => [], event: async () => ({ ok: true }) } },
})
const photo = (bytes = [1, 2, 3, 4], type = "image/png") => ({ type, arrayBuffer: async () => new Uint8Array(bytes).buffer })
const decodeAuth = h => JSON.parse(Buffer.from(h.replace(/^Nostr /, ""), "base64").toString("utf8"))
const ok = body => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => body })
const fail = (status, reason) => ({ ok: false, status, headers: { get: k => (k === "X-Reason" ? reason : null) } })

test("media servers: the account's kind 10063 in its order, dead and non-https hosts dropped; else the iPhone's defaults", () => {
  const ev = { tags: [["server", "https://cdn.example.com/"], ["server", "http://plain.example.com"], ["server", "https://cdn.satellite.earth"], ["server", "http://localhost:3355"], ["relay", "x"]] }
  assert.deepEqual(serverList(ev), ["https://cdn.example.com", "http://localhost:3355"])
  assert.deepEqual(serverList({ tags: [] }), DEFAULT_MEDIA_SERVERS)
  assert.deepEqual(serverList(undefined), ["https://blossom.nostr.build", "https://blossom.primal.net"])
})

test("media servers come from Haven first, then the account's relays (kept in Haven after)", async () => {
  const c = ctxFor(), list = finalizeEvent({ kind: 10063, created_at: 1, tags: [["server", "https://mine.example"]], content: "" }, me)
  const kept = []
  c.vault.outbox = { query: async () => [], event: async e => { kept.push(e); return { ok: true } } }
  assert.deepEqual(await mediaServers(c, { query: async () => [list] }), ["https://mine.example"])
  assert.equal(kept[0].id, list.id)
  c.vault.outbox.query = async () => [list]
  assert.deepEqual(await mediaServers(c, { query: async () => { throw new Error("network asked") } }), ["https://mine.example"])
  // Someone else's list is not this account's.
  c.vault.outbox.query = async () => []
  const theirs = finalizeEvent({ kind: 10063, created_at: 2, tags: [["server", "https://theirs.example"]], content: "" }, other)
  assert.deepEqual(await mediaServers(c, { query: async () => [theirs] }), DEFAULT_MEDIA_SERVERS)
})

test("the upload authorisation is BUD-02's: t upload, x hash, an hour's expiration", () => {
  const t = uploadAuthTemplate("ab".repeat(32), 1000)
  assert.equal(t.kind, 24242)
  assert.deepEqual(t.tags, [["t", "upload"], ["x", "ab".repeat(32)], ["expiration", "4600"]])
})

test("a photo goes to the first server that takes it, signed by the account, the hash checked", async () => {
  const file = photo(), sha = await sha256Hex(new Uint8Array([1, 2, 3, 4]))
  const calls = []
  const fetch = async (url, init) => {
    calls.push({ url, init })
    if (url.startsWith("https://down.example")) return fail(503, "busy")
    if (url.startsWith("https://liar.example")) return ok({ url: "https://liar.example/x.png", sha256: "00".repeat(32) })
    return ok({ url: `https://good.example/${sha}.png`, sha256: sha, type: "image/png" })
  }
  const up = await uploadPhoto(file, { ctx: ctxFor(), servers: ["https://down.example", "https://liar.example", "https://good.example"], fetch })
  assert.deepEqual(up, { url: `https://good.example/${sha}.png`, sha256: sha, mime: "image/png", size: 4, server: "https://good.example" })
  assert.deepEqual(calls.map(c => c.url), ["https://down.example/upload", "https://liar.example/upload", "https://good.example/upload"])
  const auth = decodeAuth(calls[2].init.headers.Authorization)
  assert.equal(calls[2].init.method, "PUT")
  assert.equal(auth.kind, 24242)
  assert.equal(auth.pubkey, pk(me))
  assert.ok(verifyEvent(auth))
  assert.deepEqual(auth.tags.find(t => t[0] === "x"), ["x", sha])
  // One signature for every server tried.
  assert.equal(new Set(calls.map(c => c.init.headers.Authorization)).size, 1)
})

test("no server took it: every reason is in the error", async () => {
  const fetch = async url => (url.includes("a.example") ? fail(401, "auth required") : Promise.reject(new Error("Failed to fetch")))
  await assert.rejects(uploadPhoto(photo(), { ctx: ctxFor(), servers: ["https://a.example", "https://b.example"], fetch }),
    /No media server took it\. a\.example: auth required · b\.example: Failed to fetch/)
})

test("a signer on another account never uploads", async () => {
  let fetched = 0
  await assert.rejects(uploadPhoto(photo(), { ctx: ctxFor(other), servers: ["https://a.example"], fetch: async () => { fetched++ } }), /different account/)
  assert.equal(fetched, 0)
})

test("imeta: url, m, x, dim, size, alt; unknown fields left out", () => {
  assert.deepEqual(imetaTag({ url: "https://x/a.jpg", mime: "image/jpeg", sha256: "ab", width: 640, height: 480, size: 99, alt: "a\nb" }),
    ["imeta", "url https://x/a.jpg", "m image/jpeg", "x ab", "dim 640x480", "size 99", "alt a b"])
  assert.deepEqual(imetaTag({ url: "https://x/a.jpg" }), ["imeta", "url https://x/a.jpg"])
  assert.equal(imetaTag({}), null)
})

test("the @query at the caret: at the start or after a space, until a space", () => {
  assert.deepEqual(mentionAt("hi @al", 6), { start: 3, end: 6, query: "al" })
  assert.deepEqual(mentionAt("@", 1), { start: 0, end: 1, query: "" })
  assert.equal(mentionAt("mail@al", 7), null)
  assert.equal(mentionAt("hi @al there", 12), null)
  assert.deepEqual(mentionAt("hi @al there", 6), { start: 3, end: 6, query: "al" })
})

const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)

test("tokens are unique: a second person with the same name gets a pubkey suffix", () => {
  assert.equal(uniqueToken("Alice", A, {}), "@Alice")
  assert.equal(uniqueToken("Alice", A, { "@Alice": A }), "@Alice")
  assert.equal(uniqueToken("Alice", B, { "@Alice": A }), "@Alice·bbbbbbbb")
  assert.equal(uniqueToken("", C, {}), "@cccccccc")
})

test("posting: tokens become nostr:npub (longest first, whole tokens only), and only the ones still there get p tags", () => {
  const map = { "@Al": A, "@Alice": B, "@Gone": C }
  const text = "hi @Alice and @Al, not @Alfred"
  assert.equal(toNostr(text, map), `hi nostr:${npubEncode(B)} and nostr:${npubEncode(A)}, not @Alfred`)
  assert.deepEqual(mentionedPubkeys(text, map).sort(), [A, B].sort())
})

test("suggestions: follows first, then names starting with the query, then shorter names", () => {
  for (const [pkx, name] of [[A, "Zed Alpha"], [B, "Alpha"], [C, "Alphabet"]])
    putProfile({ kind: 0, pubkey: pkx, created_at: 1, content: JSON.stringify({ name }) })
  assert.deepEqual(rankPeople("alp", [A, B, C], [A]), [A, B, C])
  assert.deepEqual(rankPeople("alp", [A, B, C], []), [B, C, A])
  assert.deepEqual(rankPeople("nobody", [A, B, C], [A]), [])
})

test("a post with a mention and photos: reply tags, the mention's p tag once, a link and an imeta per photo", () => {
  const author = generateSecretKey()
  const parent = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "root" }, author)
  const photos = [{ url: "https://m/1.png", mime: "image/png", sha256: "11", width: 2, height: 1, size: 5 }, { url: "https://m/2.png" }]
  const { content, tags } = buildPost({ text: "  look @Alice  ", mentions: { "@Alice": A, "@Old": B }, photos, target: { mode: "reply", id: parent.id }, parent })
  assert.equal(content, `look nostr:${npubEncode(A)}\nhttps://m/1.png\nhttps://m/2.png`)
  assert.deepEqual(tags, [
    ["e", parent.id, "", "root", parent.pubkey], ["p", parent.pubkey], ["p", A],
    ["imeta", "url https://m/1.png", "m image/png", "x 11", "dim 2x1", "size 5"], ["imeta", "url https://m/2.png"],
  ])
})

test("a quote with a photo: the photo link before the nevent line", () => {
  const author = generateSecretKey()
  const parent = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "q" }, author)
  const { content, tags } = buildPost({ text: "", mentions: {}, photos: [{ url: "https://m/1.png" }], target: { mode: "quote", id: parent.id }, parent })
  const [link, ref] = content.split("\nnostr:")
  assert.equal(link, "https://m/1.png")
  assert.equal(decode(ref).data.id, parent.id)
  assert.equal(tags[0][0], "q")
})

test("typed #hashtags become t tags (NoteTagging), once each, and a URL fragment doesn't", () => {
  const { content, tags } = buildPost({ text: "gm #Nostr #nostr see https://x.com/a#b #日本", mentions: {}, photos: [], target: null, parent: null })
  assert.equal(content, "gm #Nostr #nostr see https://x.com/a#b #日本")
  assert.deepEqual(tags.filter(t => t[0] === "t"), [["t", "nostr"], ["t", "日本"]])
})

test("a draft keeps the text, the mentions still in it and only uploaded photos; one per target", () => {
  const d = draftOf("hi @Alice", { "@Alice": A, "@Bob": B }, [{ id: 1, url: "https://m/1.png", sha256: "1", preview: "blob:x", file: {}, status: "done" }, { id: 2, status: "uploading", preview: "blob:y" }])
  assert.deepEqual(d, { text: "hi @Alice", mentions: { "@Alice": A }, photos: [{ url: "https://m/1.png", sha256: "1", mime: undefined, size: undefined, width: undefined, height: undefined }] })
  assert.equal(draftKey(null), "new")
  assert.equal(draftKey({ mode: "reply", id: A }), `reply:${A}`)
})

test("sign-out deletes the drafts database with Haven's own", async () => {
  const pubkey = pk(me)
  const idb = { databases: async () => [{ name: `haven:${pubkey}:drafts` }, { name: `haven:${pk(other)}:drafts` }] }
  const names = await storeNames(pubkey, idb)
  assert.ok(names.includes(`haven:${pubkey}:drafts`))
  assert.ok(!names.includes(`haven:${pk(other)}:drafts`))
})

// Review fixes (Tom, PR 699).
test("a deleted mention leaves no p tag: '@Al' doesn't match inside '@Al·bbbbbbbb' or its '-2' form", () => {
  const map = { "@Al": A, "@Al·bbbbbbbb": B, "@Al·bbbbbbbb-2": C }
  for (const [text, want] of [["hi @Al·bbbbbbbb", [B]], ["hi @Al·bbbbbbbb-2", [C]], ["@Al and @Al·bbbbbbbb", [A, B]], ["nobody", []]]) {
    const { content, pubkeys } = resolveMentions(text, map)
    assert.deepEqual(pubkeys, want, text)
    // The p tags are exactly the npubs in the content.
    assert.deepEqual([...content.matchAll(/nostr:(npub1[a-z0-9]+)/g)].map(m => decode(m[1]).data).filter((v, i, a) => a.indexOf(v) === i), want, text)
    assert.deepEqual(mentionedPubkeys(text, map), want, text)
  }
  const { tags } = buildPost({ text: "hi @Al·bbbbbbbb", mentions: map, photos: [], target: null, parent: null })
  assert.deepEqual(tags, [["p", B]])
})

test("a token must start a word: 'bob@Al' and an email stay text", () => {
  const map = { "@Al": A }
  assert.deepEqual(resolveMentions("bob@Al, mail me at x@Al", map), { content: "bob@Al, mail me at x@Al", pubkeys: [] })
  assert.deepEqual(resolveMentions("@Al\n@Al", map).pubkeys, [A])
  assert.equal(resolveMentions("(@Al)", map).pubkeys.length, 0) // as mentionAt: only after the start or whitespace
})

test("an upload answer without a sha256 is not used", async () => {
  const fetch = async url => ok(url.includes("nohash") ? { url: "https://nohash.example/x.png" } : { url: "https://good.example/y.png", sha256: await sha256Hex(new Uint8Array([9])) })
  const up = await uploadPhoto(photo([9]), { ctx: ctxFor(), servers: ["https://nohash.example", "https://good.example"], fetch })
  assert.equal(up.server, "https://good.example")
  await assert.rejects(uploadPhoto(photo([9]), { ctx: ctxFor(), servers: ["https://nohash.example"], fetch }), /nohash\.example: didn't confirm the file's hash/)
})

test("sign-out deletes the drafts database on browsers without indexedDB.databases() too", async () => {
  const pubkey = pk(me)
  const names = await storeNames(pubkey, {}) // Firefox < 126: no databases()
  assert.ok(names.includes(`haven:${pubkey}:drafts`))
})

test("photos and videos can be attached, nothing else; a tile knows a video by its mime or its file", () => {
  assert.ok(isMedia({ type: "image/heic" }) && isMedia({ type: "video/mp4" }) && isMedia({ type: "video/quicktime" }))
  assert.ok(!isMedia({ type: "application/pdf" }) && !isMedia({ type: "" }) && !isMedia(null))
  assert.ok(isVideo({ mime: "video/mp4" }) && isVideo({ file: { type: "video/webm" } }))
  assert.ok(!isVideo({ mime: "image/png" }) && !isVideo({}))
})

test("a draft keeps each attachment's ALT, and a blank one not at all", () => {
  const d = draftOf("", {}, [{ id: 1, url: "https://m/v.mp4", mime: "video/mp4", alt: "A dog on a beach", status: "done" }, { id: 2, url: "https://m/p.png", alt: "  ", status: "done" }])
  assert.equal(d.photos[0].alt, "A dog on a beach")
  assert.ok(!("alt" in d.photos[1]))
})

test("a video goes in the note as a link with its own imeta, ALT included", () => {
  const { content, tags } = buildPost({ text: "look", mentions: {}, target: null, parent: null,
    photos: [{ url: "https://m/v.mp4", mime: "video/mp4", sha256: "ab", width: 1920, height: 1080, size: 5e6, alt: "Waves\nat dusk" }] })
  assert.equal(content, "look\nhttps://m/v.mp4")
  assert.deepEqual(tags.find(t => t[0] === "imeta"), ["imeta", "url https://m/v.mp4", "m video/mp4", "x ab", "dim 1920x1080", "size 5000000", "alt Waves at dusk"])
})

test("a size refusal says so, with the file's size and the server's reason", async () => {
  const res = (status, reason) => ({ status, headers: { get: h => (h === "X-Reason" ? reason : null) } })
  assert.equal(refusal(res(413, "max 100 MB"), 250e6), "too large (250 MB), max 100 MB")
  assert.equal(refusal(res(413, null), 4.2e6), "too large (4.2 MB)")
  assert.equal(refusal(res(401, "auth required"), 1), "auth required")
  assert.equal(refusal(res(500, null), 1), "HTTP 500")
  assert.equal(megabytes(12.6e6), "13 MB")
  const fetch = async () => fail(413, "file too big")
  await assert.rejects(uploadPhoto(photo(), { ctx: ctxFor(), servers: ["https://a.example"], fetch }), /a\.example: too large \(0\.0 MB\), file too big/)
})
