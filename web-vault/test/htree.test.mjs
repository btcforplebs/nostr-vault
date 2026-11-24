// htree:// (Iris hashtree) photo links, phase 1: one CHK blob up to 2 MiB. The fixture is the real note that started
// this (MaxisClub b467f19b…, RESEARCH/NV_HTREE_MEDIA_SCOPE.md §0), plus hashtree's own CHK interop vectors and small
// end-to-end blobs, all in fixtures/HTREE_VECTORS.json (shared with Apple and Android). Nothing is published; the
// network is a fake fetch. HTREE_REAL_BLOB=<path to upload.iris.to/<blobHash>> also opens the real 948 KB photo.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { verifyEvent } from "nostr-tools/pure"

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
const { parseHtree, decodeNhash, decryptChk, fetchHtree, htreeServers, loadHtree, ownList, resetHtreeLists, sniffImage, MAX_BLOB_BYTES } = await import("../src/net/htree.js")
const { retainBlossom, releaseBlossom, resetBlossom } = await import("../src/net/blossom-uri.js")
const { NoteText } = await import("../src/components/NoteText.jsx")

const V = JSON.parse(readFileSync(new URL("./fixtures/HTREE_VECTORS.json", import.meta.url), "utf8"))
const unhex = h => Uint8Array.from(Buffer.from(h, "hex"))
const hex = b => Buffer.from(b).toString("hex")
const res = (body, status = 200) => ({ ok: status < 300, status, headers: { get: k => k === "content-length" ? String(body.length) : null }, body: null, arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) })
const server = map => { const asked = []; const f = async url => { asked.push(url); const [origin, name] = [url.slice(0, url.lastIndexOf("/")), url.slice(url.lastIndexOf("/") + 1)]; const b = map[origin]?.[name]; return b ? res(b) : res(new Uint8Array(), 404) }; f.asked = asked; return f }

test("the fixture note is real and signed, and its link reads as hash + CHK v1 key + file name", () => {
  assert.ok(verifyEvent(structuredClone(V.note.event)))
  const h = parseHtree(V.note.link)
  assert.equal(h.hash, V.note.blobHash)
  assert.equal(h.sha256, V.note.plainSha256, "the plain Blossom hash the vault keeps it under is in the link")
  assert.equal(hex(h.chk), V.note.key.slice(2))
  assert.equal(h.name, V.note.name); assert.equal(h.ext, V.note.ext)
  assert.equal(decodeNhash(V.note.link.slice(8).split("/")[0]).key.length, 33)
})

test("hashtree's CHK interop vectors decrypt, and a wrong key gives nothing", async () => {
  for (const v of V.chk) {
    const plain = await decryptChk(unhex(v.ciphertext), unhex(v.key))
    assert.equal(hex(plain), v.plain, v.name)
    assert.equal(await decryptChk(unhex(v.ciphertext), new Uint8Array(32)), null, v.name)
  }
})

test("only CHK links are read: rnd-v1, no key, a bad checksum or another bech32 stay text", () => {
  for (const v of V.notShown) assert.equal(parseHtree(v.link), null, v.name)
})

test("end to end: fetched by blob hash, checked, decrypted, checked again, drawn only when it is a picture", async () => {
  for (const v of V.e2e) {
    const h = parseHtree(v.link)
    const fetch = server({ "https://upload.iris.to": { [v.blobHash]: unhex(v.blob) } })
    const got = await fetchHtree(h, htreeServers(), { fetch })
    assert.equal(fetch.asked[0], `https://upload.iris.to/${v.blobHash}`, v.name)
    if (!v.show) { assert.equal(got, null, v.name); continue }
    assert.equal(hex(got.bytes), v.plain, v.name)
    assert.equal(got.mime, v.mime, v.name)
  }
})

test("a server sending other bytes, or a blob whose plain hash is off, is skipped for the next one", async () => {
  const v = V.e2e[0], h = parseHtree(v.link)
  const tampered = unhex(v.blob); tampered[0] ^= 1
  const fetch = server({ "https://upload.iris.to": { [v.blobHash]: tampered }, "https://theirs.example": { [v.blobHash]: unhex(v.blob) } })
  const got = await fetchHtree(h, htreeServers(["theirs.example"]), { fetch })
  assert.equal(got.server, "https://theirs.example")
  // Same blob, but the link claims another plain hash: decrypt fails the tag, never shown.
  const wrong = { ...h, chk: new Uint8Array(32).fill(9), sha256: "09".repeat(32) }
  assert.equal(await fetchHtree(wrong, ["https://theirs.example"], { fetch }), null)
})

test("servers: Iris first, then the author's, then the reader's; private ones never; past 2 MiB never read", async () => {
  assert.deepEqual(htreeServers(["https://a.example/"], ["b.example", "http://192.168.1.2", "https://upload.iris.to"]),
    ["https://upload.iris.to", "https://a.example", "https://b.example"])
  const v = V.e2e[0], h = parseHtree(v.link)
  const big = new Uint8Array(MAX_BLOB_BYTES + 1)
  assert.equal(await fetchHtree(h, ["https://upload.iris.to"], { fetch: async () => res(big) }), null)
})

test("Iris first with no list read; only on a miss the author's list (shared with blossom) and the reader's own", async () => {
  const v = V.e2e[0], h = parseHtree(v.link)
  resetBlossom(); resetHtreeLists()
  let reqs = 0, ownReads = 0
  const query = async () => { reqs++; return [{ kind: 10063, pubkey: "a".repeat(64), created_at: 1, tags: [["server", "https://theirs.example"]] }] }
  const vault = { outbox: { query: async () => { ownReads++; return [] } } }
  const atIris = server({ "https://upload.iris.to": { [v.blobHash]: unhex(v.blob) } })
  assert.ok(await loadHtree(h, { author: "a".repeat(64), relays: ["wss://r.example"], vault, me: "b".repeat(64), fetch: atIris, query }))
  assert.equal(reqs + ownReads, 0, "Iris had it: no kind 10063 read, no wait on a relay")
  const elsewhere = server({ "https://theirs.example": { [v.blobHash]: unhex(v.blob) } })
  const got = await loadHtree(h, { author: "a".repeat(64), relays: ["wss://r.example"], vault, me: "b".repeat(64), fetch: elsewhere, query })
  assert.equal(got.server, "https://theirs.example")
  assert.deepEqual(elsewhere.asked, [`https://upload.iris.to/${v.blobHash}`, `https://theirs.example/${v.blobHash}`], "Iris is asked once, not again after the lists")
  assert.equal(reqs, 1); assert.equal(ownReads, 1)
  await loadHtree(h, { author: "a".repeat(64), relays: ["wss://r.example"], vault, me: "b".repeat(64), fetch: elsewhere, query })
  assert.equal(reqs, 1, "one REQ per author for the page, the same cache blossom: links use")
  resetBlossom(); resetHtreeLists()
})

test("the reader's own list: only their own 10063, read again for another account, none for a guest", async () => {
  resetHtreeLists()
  const asked = []
  const evs = { ["b".repeat(64)]: [{ kind: 10063, pubkey: "b".repeat(64), created_at: 2, tags: [["server", "https://mine.example"]] }, { kind: 10063, pubkey: "c".repeat(64), created_at: 9, tags: [["server", "https://not-mine.example"]] }] }
  const vault = { outbox: { query: async f => { asked.push(f); return evs[f.authors?.[0]] ?? [] } } }
  assert.deepEqual(await ownList(vault, null), [], "a guest has no own list")
  assert.deepEqual(await ownList(vault, "b".repeat(64)), ["https://mine.example"])
  assert.deepEqual(asked[0], { kinds: [10063], authors: ["b".repeat(64)] })
  assert.deepEqual(await ownList(vault, "d".repeat(64)), [], "another account is read on its own, not handed b's answer")
  assert.equal(asked.length, 2)
  resetHtreeLists()
})

test("sniffImage knows the picture types and nothing else", () => {
  assert.equal(sniffImage(unhex("ffd8ffe0")), "image/jpeg")
  assert.equal(sniffImage(unhex("89504e470d0a1a0a00")), "image/png")
  assert.equal(sniffImage(new TextEncoder().encode("GIF89a..")), "image/gif")
  assert.equal(sniffImage(new TextEncoder().encode("RIFF....WEBPVP8 ")), "image/webp")
  assert.equal(sniffImage(new TextEncoder().encode("<svg>")), "")
  assert.equal(sniffImage(unhex("82a16c90a17402")), "", "a hashtree tree node is not a picture")
})

test("in the fixture note: the link is one photo element, not text", () => {
  const ev = V.note.event
  const kids = NoteText({ content: ev.content, tags: ev.tags, author: ev.pubkey }).props.children[0]
  const photos = kids.filter(k => k?.props?.h)
  assert.equal(photos.length, 1)
  assert.equal(photos[0].props.h.sha256, V.note.plainSha256)
  assert.ok(!JSON.stringify(kids.filter(k => typeof k === "string")).includes("htree:"), "no raw link in the text")
})

test("an htree photo and a blossom: link to the same file share one cache entry", async () => {
  resetBlossom()
  const v = V.e2e[0], h = parseHtree(v.link)
  let n = 0
  const fetchFile = async () => { n++; return { bytes: unhex(v.plain), mime: "image/jpeg", server: "https://upload.iris.to" } }
  const opts = { fetchFile, makeUrl: () => "blob:x", revokeUrl: () => {} }
  const a = await retainBlossom(h, opts)
  const b = await retainBlossom({ sha256: v.plainSha256, ext: "jpg", servers: [], author: null, size: null }, { fetch: async () => { throw new Error("not asked") }, makeUrl: () => "blob:y", revokeUrl: () => {} })
  assert.equal(n, 1); assert.equal(a.url, "blob:x"); assert.equal(b.url, "blob:x"); assert.equal(a.kind, "image")
  releaseBlossom(h.sha256); releaseBlossom(h.sha256); resetBlossom()
})

// Only registered when the blob is given: test-web-apps.sh fails any skipped test.
if (process.env.HTREE_REAL_BLOB) test("the real photo (HTREE_REAL_BLOB): 948,296 bytes in, a 948,280-byte JPEG out whose sha256 is in the link", async () => {
  const blob = new Uint8Array(readFileSync(process.env.HTREE_REAL_BLOB))
  const h = parseHtree(V.note.link)
  const got = await fetchHtree(h, ["https://upload.iris.to"], { fetch: async () => res(blob) })
  assert.equal(got.bytes.length, V.note.plainBytes); assert.equal(got.mime, "image/jpeg")
})
