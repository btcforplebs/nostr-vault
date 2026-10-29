// The live stream page against the iPhone's #1306, with Tron's must-fixes from that review: every chat event's
// signature is checked; a zap names its payer only when the signed request was made for this stream, else "Someone"
// with no profile, Mute or Report; four media at most per message, the rest stay text. Plus sharing (the note, the
// nostrvault.app link, the host's profile) and the chat message and zap request as sent. Throwaway keys; nothing is
// published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { decode } from "nostr-tools/nip19"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { chatRow, chatRows, payerRequest, rowOffers, splitMedia, chatTemplate, streamShareLink, profileShareLink, noteText, MAX_MEDIA } = await import("../src/readers/live-chat.js")
const { parseStream } = await import("../src/readers/live.js")
const { zapRequestTemplate } = await import("../src/net/zaps.js")
await import("../src/readers/LiveChat.jsx") // loads: the row component and its imports
const { shareNoteText } = await import("../src/readers/LiveActions.jsx")

const NOW = 1_800_000_000
const host = generateSecretKey(), HOST = getPublicKey(host)
const service = generateSecretKey(), SERVICE = getPublicKey(service)
const alice = generateSecretKey(), ALICE = getPublicKey(alice)
const stream = parseStream(finalizeEvent({ kind: 30311, created_at: NOW, content: "", tags: [["d", "room"], ["title", "Late set"], ["streaming", "https://cdn.example/live/index.m3u8"], ["image", "https://cdn.example/cover.jpg"], ["relays", "wss://relay.example"], ["p", HOST, "", "Host"]] }, service))
const msg = (sk, text, extra = [], at = NOW) => finalizeEvent({ kind: 1311, created_at: at, content: text, tags: [["a", stream.address], ...extra] }, sk)
const receipt = (req, over = {}) => finalizeEvent({ kind: 9735, created_at: NOW + 1, content: "", tags: [["p", HOST], ["a", stream.address], ["bolt11", "lnbc210n1x"], ["description", JSON.stringify(req)]], ...over }, service)
const request = (sk, tags = [["a", stream.address]], content = "great set") => finalizeEvent({ kind: 9734, created_at: NOW, content, tags: [["p", HOST], ["amount", "21000"], ...tags] }, sk)

test("every chat event's own signature is checked, and it must be tagged with this stream", () => {
  const good = msg(alice, " hi ")
  assert.deepEqual(chatRow(good, stream.address)?.who, ALICE)
  assert.equal(chatRow(good, stream.address).text, "hi")
  assert.equal(chatRow({ ...good, content: "edited" }, stream.address), null, "a changed message no longer verifies")
  assert.equal(chatRow({ ...good, pubkey: HOST }, stream.address), null, "words under someone else's name")
  assert.equal(chatRow({ ...good, sig: undefined }, stream.address), null, "unsigned")
  assert.equal(chatRow(msg(alice, "elsewhere", [], NOW), "30311:" + "b".repeat(64) + ":other"), null, "another stream's chat")
  assert.equal(chatRow({ ...good, verified: true, content: "x" }, stream.address), null, "a 'verified' mark on the object is not trusted")
})

test("a zap names its payer only when the signed request was made for this stream; else Someone", () => {
  const ok = chatRow(receipt(request(alice)), stream.address)
  assert.equal(ok.who, ALICE); assert.equal(ok.sats, 21); assert.equal(ok.text, "great set"); assert.equal(ok.zap, true)
  const other = chatRow(receipt(request(alice, [["e", "c".repeat(64)]])), stream.address)
  assert.equal(other.who, null, "a real request made for another note, rewrapped for this stream")
  const forged = request(alice); forged.content = "I paid"
  assert.equal(chatRow(receipt(forged), stream.address).who, null, "a request that no longer verifies")
  const claimed = { ...request(alice), pubkey: HOST }
  assert.equal(chatRow(receipt(claimed), stream.address).who, null, "a request naming a victim's key it isn't signed by")
  assert.equal(payerRequest(receipt(request(alice)), stream.address).pubkey, ALICE)
  assert.equal(chatRow({ ...receipt(request(alice)), content: "x" }, stream.address), null, "the receipt itself is checked too")
  // Someone is never hidden as anyone's, and has nothing to open, mute or report.
  const rows = chatRows([receipt(claimed), msg(alice, "hi")], stream.address, new Set([HOST]))
  assert.equal(rows.length, 2, "a blocked host doesn't hide a zap that names nobody")
  assert.ok(rows.some(r => r.who === null))
  assert.deepEqual(rowOffers(rows.find(r => r.who === null), ALICE), { label: "Someone", profile: null, mute: false, report: false })
  assert.deepEqual(rowOffers(ok, HOST), { label: null, profile: `#/profile/${ALICE}`, mute: true, report: true })
  assert.deepEqual(rowOffers(ok, ALICE), { label: null, profile: `#/profile/${ALICE}`, mute: false, report: true }, "no Mute on yourself")
  assert.deepEqual(rowOffers(ok, HOST, true), { label: null, profile: `#/profile/${ALICE}`, mute: false, report: false }, "read-only can only look")
  const src = readFileSync(new URL("../src/readers/LiveChat.jsx", import.meta.url), "utf8")
  assert.match(src, /rowOffers\(r, ctx\.session\?\.pubkey/, "the row draws from rowOffers")
})

test("blocked people's messages are left out; rows come oldest first, once each", () => {
  const a = msg(alice, "first", [], NOW), h = msg(host, "from the host", [], NOW + 5), again = a
  const rows = chatRows([h, a, again], stream.address, new Set([HOST]))
  assert.deepEqual(rows.map(r => r.text), ["first"])
  assert.deepEqual(chatRows([h, a], stream.address).map(r => r.text), ["first", "from the host"])
})

test("media: photos, GIFs and videos come out of the text, four at most; the rest stay text", () => {
  const links = ["a.jpg", "b.gif", "c.mp4", "d.png", "e.webp"].map(f => `https://m.example/${f}`)
  const { text, media } = splitMedia(`look ${links.join(" ")} nice\n${links[0]} again`)
  assert.equal(MAX_MEDIA, 4)
  assert.deepEqual(media, links.slice(0, 4))
  assert.equal(text, `look ${links[4]} nice\nagain`, "the fifth stays as text; a repeat isn't shown twice")
  assert.deepEqual(splitMedia("https://example.com/page and words").media, [])
})

test("the chat message and the zap request carry this stream", () => {
  const t = chatTemplate(stream.address, "  hello  ", NOW)
  assert.deepEqual(t, { kind: 1311, created_at: NOW, tags: [["a", stream.address, "wss://relay.zap.stream"]], content: "hello" })
  const z = zapRequestTemplate({ recipient: HOST, address: stream.address, amountMsat: 21000, relays: ["wss://r.example"], lnurl: "lnurl1x", content: "go" })
  assert.ok(z.tags.some(t => t[0] === "a" && t[1] === stream.address)); assert.equal(z.content, "go")
  assert.ok(!zapRequestTemplate({ recipient: HOST, amountMsat: 1000, relays: [], lnurl: "x" }).tags.some(t => t[0] === "a"), "a note zap is unchanged")
})

test("sharing: the nostrvault.app link by naddr, the host's profile page, and the note to post", () => {
  const link = streamShareLink(stream)
  assert.match(link, /^https:\/\/nostrvault\.app\/thread\/naddr1/)
  const d = decode(link.split("/thread/")[1]).data
  assert.deepEqual([d.kind, d.pubkey, d.identifier], [30311, SERVICE, "room"])
  assert.match(profileShareLink(HOST), /^https:\/\/nostrvault\.app\/p\/npub1/)
  assert.equal(noteText({ title: "Late set", hostName: "Ann", picture: "https://p/x.jpg", streaming: "https://s/i.m3u8", naddr: "naddr1x" }),
    "Late set, live now with Ann\n\nhttps://p/x.jpg\nhttps://s/i.m3u8\nnostr:naddr1x")
  assert.equal(noteText({ hostName: "Ann" }), "Ann is live now")
  const text = shareNoteText(stream)
  assert.match(text, /^Late set, live now with /); assert.match(text, /\nhttps:\/\/cdn\.example\/cover\.jpg\nhttps:\/\/cdn\.example\/live\/index\.m3u8\nnostr:naddr1/)
})
