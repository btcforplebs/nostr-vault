// A DM photo is a NIP-17 kind 15 file message (Tron, DM privacy 2026-11-14): the file is AES-GCM encrypted before it
// goes up, the media server holds only ciphertext (its hash is the x tag), and the key and nonce travel inside the
// sealed message. Reading fetches the ciphertext, checks its hash and decrypts; an old plain photo link still shows.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { encryptFile, decryptFile, fileLink, parseFileLink, fileMessage, openFileLink, isFileLink, encryptedPhoto } from "../src/net/dm-file.js"
import { unwrap, wrapFor, rumorFor, sendMessage, resetMessages, getMessages, lastPreview } from "../src/net/dms.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const cryptoOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
  decrypt04: async (peer, c) => nip04.decrypt(sk, peer, c),
})
const envOf = sk => ({ signer: { signEvent: async t => finalizeEvent(t, sk) }, crypto: cryptoOf(sk), me: pk(sk) })
const ctxOf = sk => ({ vault: {}, session: { method: "nip07", pubkey: pk(sk) }, signer: envOf(sk).signer, account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] } } })
const fakeChat = () => ({ stored: [], query: async () => [], event: async () => ({ ok: true }) })
const hex = b => Buffer.from(b).toString("hex")
const sha = async b => hex(await crypto.subtle.digest("SHA-256", b))
const PLAIN = new TextEncoder().encode("\xff\xd8 a photo only Bob should see")
const URL_ = "https://blossom.example/" + "c".repeat(64)

test("the file is encrypted with a fresh AES-GCM key: x is the ciphertext's hash, ox the original's", async () => {
  const a = await encryptFile(PLAIN), b = await encryptFile(PLAIN)
  assert.match(a.key, /^[0-9a-f]{64}$/); assert.match(a.nonce, /^[0-9a-f]{24}$/)
  assert.notEqual(a.key, b.key); assert.notEqual(a.nonce, b.nonce)
  assert.equal(a.x, await sha(a.cipher)); assert.equal(a.ox, await sha(PLAIN))
  assert.ok(!Buffer.from(a.cipher).toString("latin1").includes("only Bob"), "no plaintext in what goes up")
  assert.deepEqual(await decryptFile(a.cipher, a), PLAIN)
})

test("a ciphertext that isn't the one named, or was changed, doesn't open", async () => {
  const a = await encryptFile(PLAIN)
  const bent = a.cipher.slice(); bent[3] ^= 1
  await assert.rejects(decryptFile(bent, a), /changed/)
  await assert.rejects(decryptFile(bent, { ...a, x: undefined })) // GCM's tag catches it with no hash too
  await assert.rejects(decryptFile(a.cipher, { ...a, key: (await encryptFile(PLAIN)).key }))
})

test("the kind 15 names the URL and carries what's needed to open it, nothing about the original but its hash", async () => {
  const enc = await encryptFile(PLAIN)
  const m = fileMessage(URL_, enc, { mime: "image/jpeg" })
  assert.equal(m.kind, 15); assert.equal(m.content, URL_)
  const tag = k => m.tags.find(t => t[0] === k)?.[1]
  assert.equal(tag("file-type"), "image/jpeg"); assert.equal(tag("encryption-algorithm"), "aes-gcm")
  assert.equal(tag("decryption-key"), enc.key); assert.equal(tag("decryption-nonce"), enc.nonce)
  assert.equal(tag("x"), enc.x); assert.equal(tag("ox"), enc.ox); assert.equal(tag("size"), String(enc.cipher.length))
  assert.ok(parseFileLink(m.shown), "the sender's own bubble opens it too")
})

test("the link kept on this device holds key, nonce, hash and type in its fragment, which no fetch sends", async () => {
  const enc = await encryptFile(PLAIN)
  const link = fileLink(URL_, { ...enc, mime: "image/gif" })
  assert.ok(link.startsWith(URL_ + "#nv-dm=")); assert.ok(isFileLink(link)); assert.ok(!isFileLink(URL_))
  assert.match(link, /[A-Za-z0-9_-]$/, "nothing a link trimmer would cut")
  assert.deepEqual(parseFileLink(link), { url: URL_, key: enc.key, nonce: enc.nonce, x: enc.x, mime: "image/gif" })
  assert.equal(parseFileLink(URL_ + "#nv-dm=junk"), null)
  assert.equal(parseFileLink("http://plain.example/a#nv-dm=" + link.split("#nv-dm=")[1]), null, "https only")
})

test("openFileLink fetches the ciphertext without the fragment, checks it, and hands back the photo", async () => {
  const enc = await encryptFile(PLAIN)
  const asked = []
  const blob = await openFileLink(fileLink(URL_, { ...enc, mime: "image/jpeg" }), { fetchBytes: async u => { asked.push(u); return enc.cipher } })
  assert.deepEqual(asked, [URL_])
  assert.equal(blob.type, "image/jpeg")
  assert.deepEqual(new Uint8Array(await blob.arrayBuffer()), PLAIN)
  await assert.rejects(openFileLink(fileLink(URL_, { ...enc, mime: "image/jpeg" }), { fetchBytes: async () => PLAIN }))
})

test("encryptedPhoto uploads only the ciphertext, as raw bytes, and returns the kind 15", async () => {
  let up
  const file = new File([PLAIN], "a.jpg", { type: "image/jpeg" })
  const m = await encryptedPhoto(file, { upload: async f => { up = new Uint8Array(await f.arrayBuffer()); return { url: URL_, sha256: await sha(up) } } })
  assert.ok(!Buffer.from(up).toString("latin1").includes("only Bob"))
  assert.equal(m.tags.find(t => t[0] === "x")[1], await sha(up))
  await assert.rejects(encryptedPhoto(file, { upload: async () => ({ url: URL_, sha256: "0".repeat(64) }) }), /didn't upload/)
})

test("a kind 15 wrap opens as the photo for the other person, and an old kind 14 link still opens as text", async () => {
  const enc = await encryptFile(PLAIN)
  const m = fileMessage(URL_, enc, { mime: "image/jpeg" })
  const rumor = rumorFor(pk(A), pk(B), m.content, undefined, { kind: 15, tags: m.tags })
  assert.equal(rumor.kind, 15); assert.deepEqual(rumor.tags[0], ["p", pk(B)])
  const got = await unwrap(await wrapFor(rumor, envOf(A), pk(B)), cryptoOf(B), pk(B))
  assert.deepEqual(parseFileLink(got.content), { url: URL_, key: enc.key, nonce: enc.nonce, x: enc.x, mime: "image/jpeg" })
  assert.equal(lastPreview(got.content), "Photo")
  const old = await unwrap(await wrapFor(rumorFor(pk(A), pk(B), "look\n" + URL_ + ".jpg"), envOf(A), pk(B)), cryptoOf(B), pk(B))
  assert.equal(old.content, "look\n" + URL_ + ".jpg")
  // A kind 15 with no usable key: just its link, which shows as an old photo would.
  const bare = await unwrap(await wrapFor(rumorFor(pk(A), pk(B), URL_, undefined, { kind: 15, tags: [["file-type", "image/jpeg"]] }), envOf(A), pk(B)), cryptoOf(B), pk(B))
  assert.equal(bare.content, URL_)
  const junk = await unwrap(await wrapFor(rumorFor(pk(A), pk(B), "not a url", undefined, { kind: 15, tags: [] }), envOf(A), pk(B)), cryptoOf(B), pk(B))
  assert.equal(junk, null)
})

test("sendMessage with a photo: the text goes as a kind 14, the photo as a kind 15, no plain link anywhere", async () => {
  const enc = await encryptFile(PLAIN)
  const sent = []
  resetMessages(pk(A))
  const publish = (urls, ev) => { sent.push(ev); return [Promise.resolve("ok")] }
  await sendMessage(ctxOf(A), pk(B), "look", { crypto: cryptoOf(A), query: async () => [], chat: fakeChat(), publish, preview: "look\n(photo)", prepare: async () => fileMessage(URL_, enc, { mime: "image/jpeg" }) })
  const opened = await Promise.all(sent.filter(e => e.tags[0][1] === pk(B)).map(w => unwrap(w, cryptoOf(B), pk(B))))
  assert.deepEqual(opened.map(m => parseFileLink(m.content) ? "photo" : m.content), ["look", "photo"])
  assert.ok(opened[1].at > opened[0].at, "the photo sorts after its words")
  const mine = [...getMessages().messages.values()].sort((a, b) => a.at - b.at)
  assert.deepEqual(mine.map(m => parseFileLink(m.content) ? "photo" : m.content), ["look", "photo"])
  assert.ok(mine.every(m => !m.pending && !m.failed))
})

test("a photo that went up but whose message didn't go keeps its upload for Try again", async () => {
  const enc = await encryptFile(PLAIN)
  let uploads = 0, ok = false
  resetMessages(pk(A))
  const publish = () => [ok ? Promise.resolve("ok") : Promise.reject(new Error("no"))]
  const prepare = async () => { uploads++; return fileMessage(URL_, enc, { mime: "image/jpeg" }) }
  await assert.rejects(sendMessage(ctxOf(A), pk(B), "", { crypto: cryptoOf(A), query: async () => [], chat: fakeChat(), publish, preview: "(photo)", prepare }), /Not delivered/)
  const [failed] = getMessages().messages.values()
  assert.ok(failed.failed)
  ok = true
  await failed.resend()
  assert.equal(uploads, 1, "not uploaded twice")
  const [m] = getMessages().messages.values()
  assert.ok(parseFileLink(m.content))
})

test("a file whose server never stops sending is cut off at the cap, not read until the tab dies (Tron #2)", async () => {
  const enc = await encryptFile(PLAIN)
  const real = globalThis.fetch
  let sent = 0
  globalThis.fetch = async () => new Response(new ReadableStream({ pull(c) { if (sent >= 70 * (1 << 20)) return c.close(); sent += 1 << 20; c.enqueue(new Uint8Array(1 << 20)) } }))
  try { await assert.rejects(openFileLink(fileLink(URL_, { ...enc, mime: "image/jpeg" })), /too large/) } finally { globalThis.fetch = real }
  assert.ok(sent <= 62 * (1 << 20), `read ${sent} bytes`)
})

test("a 16-byte nonce from another NIP-17 app opens too", async () => {
  const tags = [["file-type", "image/jpeg"], ["encryption-algorithm", "aes-gcm"], ["decryption-key", "a".repeat(64)], ["decryption-nonce", "b".repeat(32)]]
  const r = rumorFor(pk(A), pk(B), URL_, undefined, { kind: 15, tags })
  const got = await unwrap(await wrapFor(r, envOf(A), pk(B)), cryptoOf(B), pk(B))
  assert.equal(parseFileLink(got.content)?.nonce, "b".repeat(32))
})
