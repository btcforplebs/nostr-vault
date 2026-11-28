// Uploads publish a small copy for Media grids: a photo's imeta `thumb`, a video's poster `image` (net/upload-preview.js,
// net/upload.js). The copy never blocks or fails the upload.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { imetaTag, sha256Hex, uploadAuthTemplate, uploadPhoto } from "../src/net/upload.js"
import { previewOf, THUMB_EDGE, POSTER_EDGE } from "../src/net/upload-preview.js"

const me = generateSecretKey()
const ctxFor = (signs = []) => ({
  session: { pubkey: getPublicKey(me) },
  signer: { signEvent: async t => { signs.push(t); return finalizeEvent(t, me) } },
})
const file = (bytes, type) => new File([new Uint8Array(bytes)], "x", { type })
const ok = body => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => body })
const fail = status => ({ ok: false, status, headers: { get: () => null } })
const authOf = h => JSON.parse(Buffer.from(h.replace(/^Nostr /, ""), "base64").toString())
const MAIN = [1, 2, 3, 4], SMALL = [9, 9, 9]
const thumbOf = async () => ({ field: "thumb", file: file(SMALL, "image/jpeg") })

// A server that keeps what it's given (by the hash of the bytes); `refuse(bytes)` -> a status to answer instead.
function server(host, { refuse = () => 0, calls = [] } = {}) {
  return async (url, init) => {
    calls.push({ url, init })
    if (init.method === "HEAD") return ok({})
    if (!url.startsWith(host)) return fail(503)
    const b = new Uint8Array(init.body), no = refuse(b)
    if (no) return fail(no)
    const sha = await sha256Hex(b)
    return ok({ url: `${host}/${sha}.jpg`, sha256: sha })
  }
}

test("a photo's thumb goes up with it under the same authorisation: one signer prompt, both hashes, file's first", async () => {
  const signs = [], calls = []
  const up = await uploadPhoto(file(MAIN, "image/jpeg"), { ctx: ctxFor(signs), servers: ["https://a.example"], fetch: server("https://a.example", { calls }), preview: thumbOf })
  const [main, small] = [await sha256Hex(new Uint8Array(MAIN)), await sha256Hex(new Uint8Array(SMALL))]
  assert.equal(signs.length, 1)
  assert.deepEqual(signs[0].tags.filter(t => t[0] === "x").map(t => t[1]), [main, small])
  assert.equal(up.url, `https://a.example/${main}.jpg`)
  assert.equal(up.thumb, `https://a.example/${small}.jpg`)
  const puts = calls.filter(c => c.init.method === "PUT")
  assert.equal(puts.length, 2)
  assert.equal(authOf(puts[1].init.headers.Authorization).id, authOf(puts[0].init.headers.Authorization).id)
  assert.equal(puts[1].init.headers["Content-Type"], "image/jpeg")
  assert.deepEqual(imetaTag({ ...up, width: 2016, height: 1512 }), ["imeta", `url ${up.url}`, "m image/jpeg", `x ${main}`, "dim 2016x1512", "size 4", `thumb ${up.thumb}`])
})

test("the small copy goes to the server that took the file, not the one that refused it", async () => {
  const calls = []
  const up = await uploadPhoto(file(MAIN, "image/jpeg"), { ctx: ctxFor(), servers: ["https://down.example", "https://b.example"], fetch: server("https://b.example", { calls }), preview: thumbOf })
  assert.match(up.thumb, /^https:\/\/b\.example\//)
  assert.equal(calls.filter(c => c.init.method === "PUT" && c.url.startsWith("https://down.example")).length, 1) // the file only
})

test("a video's poster is published as `image`", async () => {
  const poster = async () => ({ field: "image", file: file(SMALL, "image/jpeg") })
  const up = await uploadPhoto(file(MAIN, "video/mp4"), { ctx: ctxFor(), servers: ["https://a.example"], fetch: server("https://a.example"), preview: poster })
  assert.match(up.image, /^https:\/\/a\.example\//)
  assert.equal(up.thumb, undefined)
  assert.ok(imetaTag(up).includes(`image ${up.image}`))
})

test("no thumb never stops the upload: refused, thrown, wrong hash, or no preview made", async () => {
  const main = await sha256Hex(new Uint8Array(MAIN)), isSmall = b => b.length === SMALL.length
  const cases = {
    refused: { fetch: server("https://a.example", { refuse: b => (isSmall(b) ? 415 : 0) }) },
    thrown: { fetch: async (u, i) => (i.method === "PUT" && new Uint8Array(i.body).length === SMALL.length ? Promise.reject(new TypeError("Failed to fetch")) : server("https://a.example")(u, i)) },
    wrongHash: { fetch: async (u, i) => (i.method === "PUT" && new Uint8Array(i.body).length === SMALL.length ? ok({ url: "https://a.example/z.jpg", sha256: "00".repeat(32) }) : server("https://a.example")(u, i)) },
    previewThrows: { fetch: server("https://a.example"), preview: async () => { throw new Error("no canvas") } },
    previewNull: { fetch: server("https://a.example"), preview: async () => null },
  }
  for (const [name, c] of Object.entries(cases)) {
    const signs = []
    const up = await uploadPhoto(file(MAIN, "image/jpeg"), { ctx: ctxFor(signs), servers: ["https://a.example"], fetch: c.fetch, preview: c.preview ?? thumbOf })
    assert.equal(up.url, `https://a.example/${main}.jpg`, name)
    assert.equal(up.thumb, undefined, name)
    assert.ok(!imetaTag(up).some(f => /^thumb /.test(f)), name)
    if (c.preview) assert.equal(signs[0].tags.filter(t => t[0] === "x").length, 1, name) // nothing to cover
  }
})

test("without a preview the upload is as before: one x, one PUT", async () => {
  const signs = [], calls = []
  await uploadPhoto(file(MAIN, "image/jpeg"), { ctx: ctxFor(signs), servers: ["https://a.example"], fetch: server("https://a.example", { calls }) })
  assert.equal(signs[0].tags.filter(t => t[0] === "x").length, 1)
  assert.equal(calls.filter(c => c.init.method === "PUT").length, 1)
  assert.deepEqual(uploadAuthTemplate("ab".repeat(32), 1000, ["ab".repeat(32), "", "cd".repeat(32)]).tags,
    [["t", "upload"], ["x", "ab".repeat(32)], ["x", "cd".repeat(32)], ["expiration", "4600"]])
})

test("imeta leaves out a thumb or image that is the file itself", () => {
  assert.deepEqual(imetaTag({ url: "https://a/x", thumb: "https://a/x", image: "https://a/x" }), ["imeta", "url https://a/x"])
})

// previewOf with drawing stubbed: what it asks to be drawn, and when it makes nothing.
const bmp = (width, height) => ({ width, height, closed: 0, close() { this.closed++ } })
const drawn = []
const draw = async (b, o) => { drawn.push(o); return new Blob([new Uint8Array(o.maxEdge / 10)], { type: o.type }) }

test("a photo's thumb is a 320 px JPEG; a small photo, a GIF or an undrawable one gets none", async () => {
  drawn.length = 0
  const big = bmp(2016, 1512)
  const p = await previewOf(file([1], "image/jpeg"), { decode: async () => big, draw })
  assert.equal(p.field, "thumb")
  assert.equal(p.file.type, "image/jpeg")
  assert.deepEqual(drawn[0], { type: "image/jpeg", maxEdge: THUMB_EDGE, quality: 0.8 })
  assert.equal(big.closed, 1)
  assert.equal(await previewOf(file([1], "image/png"), { decode: async () => bmp(320, 200), draw }), null)
  assert.equal(await previewOf(file([1], "image/gif"), { decode: async () => bmp(2000, 2000), draw }), null)
  assert.equal(await previewOf(file([1], "image/heic"), { decode: async () => { throw new Error("can't") }, draw }), null)
  assert.equal(await previewOf(file([1], "application/pdf"), { decode: async () => bmp(2000, 2000), draw }), null)
  assert.equal(await previewOf(file([1], "image/jpeg"), { decode: async () => bmp(2000, 2000), draw: async () => null }), null)
})

test("a video's poster is one frame at 640 px; a video the browser can't play gets none", async () => {
  drawn.length = 0
  const still = bmp(1280, 720)
  const p = await previewOf(file([1], "video/mp4"), { frame: async () => still, draw })
  assert.equal(p.field, "image")
  assert.deepEqual(drawn[0], { type: "image/jpeg", maxEdge: POSTER_EDGE, quality: 0.8 })
  assert.equal(still.closed, 1)
  assert.equal(await previewOf(file([1], "video/x-matroska"), { frame: async () => { throw new Error("can't play") }, draw }), null)
})
