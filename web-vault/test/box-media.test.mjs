// Vault › Media in box mode (box/box-media.js): the box's own Blossom first in the server list, its plain-http LAN
// links kept for Media only, and Copy to servers for a file only the box holds (the browser reads it from the box and
// uploads the same bytes, since a public server can't reach the LAN). Throwaway keys, a fake fetch: nothing is sent.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { boxMediaServer, withBox, mediaLinkOk, publicSource, copyToServers } from "../src/box/box-media.js"
import { uploadPhoto } from "../src/net/upload.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const ctx = { session: { pubkey: ME }, signer: { signEvent: async t => finalizeEvent(t, SK) } }
const H = c => c.repeat(64)
const BOXO = "http://box.lan:8080", A = "https://a.example", B = "https://b.example"
const on = { box: true, loc: { origin: BOXO } }
const res = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body, blob: async () => new Blob([new Uint8Array([1, 2, 3])]), headers: { get: () => null } })

test("outside box mode nothing changes", () => {
  assert.equal(boxMediaServer({ box: false, loc: { origin: BOXO } }), null)
  assert.deepEqual(withBox([A, B], { box: false, loc: { origin: BOXO } }), [A, B])
  assert.equal(mediaLinkOk(`${BOXO}/${H("a")}.jpg`, { box: false, loc: { origin: BOXO } }), false)
  assert.equal(mediaLinkOk(`${A}/${H("a")}.jpg`, { box: false }), true)
})

test("in box mode the box comes first, once", () => {
  assert.equal(boxMediaServer(on), BOXO)
  assert.deepEqual(withBox([A, B], on), [BOXO, A, B])
  assert.deepEqual(withBox([A, BOXO], on), [BOXO, A])
  assert.deepEqual(withBox([], on), [BOXO])
  assert.equal(mediaLinkOk(`${BOXO}/${H("a")}.jpg`, on), true)
  assert.equal(mediaLinkOk(`http://other.lan/${H("a")}.jpg`, on), false)
})

test("a public link is kept as the source; a box link swaps to a public server that holds it", () => {
  assert.equal(publicSource({ sha256: H("a"), url: `${A}/${H("a")}.png`, servers: [A] }), `${A}/${H("a")}.png`)
  assert.equal(publicSource({ sha256: H("a"), url: `${BOXO}/${H("a")}.png`, servers: [BOXO, B] }), `${B}/${H("a")}.png`)
  assert.equal(publicSource({ sha256: H("a"), url: `${BOXO}/${H("a")}.png`, servers: [BOXO] }), null)
})

test("Copy to servers: the box's file goes to a public server by mirror from a public copy", async () => {
  const blob = { sha256: H("b"), url: `${BOXO}/${H("b")}.jpg`, type: "image/jpeg", servers: [BOXO, A] }
  const asked = []
  const r = await copyToServers(blob, [BOXO, A, B], { ctx, fetch: async (url, opt) => { asked.push([url, JSON.parse(opt.body).url]); return res(200, { sha256: H("b") }) }, upload: () => assert.fail("uploaded") })
  assert.deepEqual(asked, [[`${B}/mirror`, `${A}/${H("b")}.jpg`]])
  assert.deepEqual(r, [{ server: B, ok: true, message: "" }])
})

test("Copy to servers: a file only on the box is read from it and uploaded as is", async () => {
  const blob = { sha256: H("c"), url: `${BOXO}/${H("c")}.jpg`, type: "image/jpeg", servers: [BOXO] }
  const uploads = []
  const fetch = async (url, opt) => { assert.equal(url, blob.url); assert.equal(opt, undefined); return res(200) }
  const upload = async (file, o) => { uploads.push([o.servers, o.raw, file.type]); if (o.servers[0] === B) throw new Error(`No media server took it. b.example: HTTP 413`); return { sha256: H("c") } }
  const r = await copyToServers(blob, [BOXO, A, B], { ctx, fetch, upload })
  assert.deepEqual(uploads, [[[A], true, "image/jpeg"], [[B], true, "image/jpeg"]])
  assert.deepEqual(r, [{ server: A, ok: true, message: "" }, { server: B, ok: false, message: "b.example: HTTP 413" }])
})

test("Copy to servers: a box that won't give the file back fails each server with the reason", async () => {
  const blob = { sha256: H("d"), url: `${BOXO}/${H("d")}`, servers: [BOXO] }
  const r = await copyToServers(blob, [BOXO, A], { ctx, fetch: async () => res(404), upload: () => assert.fail("uploaded") })
  assert.deepEqual(r, [{ server: A, ok: false, message: "couldn't read it from your box (HTTP 404)" }])
})

test("upload: the box's own http link is kept only with the box's link check", async () => {
  const bytes = new Uint8Array([7, 7, 7])
  const file = { type: "image/png", arrayBuffer: async () => bytes.buffer }
  let sha = null
  const fetch = async (url, opt) => {
    if (opt.method === "HEAD") return res(200)
    sha = JSON.parse(atob(opt.headers.Authorization.slice(6))).tags.find(t => t[0] === "x")[1]
    return res(200, { sha256: sha, url: `${BOXO}/${sha}.png` })
  }
  await assert.rejects(uploadPhoto(file, { ctx, servers: [BOXO], fetch, raw: true }), /no link in its answer/)
  const r = await uploadPhoto(file, { ctx, servers: [BOXO], fetch, raw: true, linkOk: u => mediaLinkOk(u, on) })
  assert.equal(r.url, `${BOXO}/${sha}.png`)
  assert.equal(r.server, BOXO)
})
