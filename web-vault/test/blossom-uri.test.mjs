// BUD-10 blossom: links: parsed from a note's text, asked of the link's servers, then the author's list, then the usual
// ones, and shown only when the bytes hash to the sha256 the link names. Never a loopback or private server. The note
// text keeps the link out of the text and out of the https carousel. Nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { createHash } from "node:crypto"
import { transformSync } from "rolldown/utils"

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
const { parseBlossomUri, serverOrigin, candidateServers, fetchVerified, loadBlossom, resetBlossom, blossomKind, MAX_SERVERS } = await import("../src/net/blossom-uri.js")
const { NoteText } = await import("../src/components/NoteText.jsx")

// The test post (Laan Tungir, nevent1qqsqqqqxk8fs9…): its blossom: link exactly.
const LINK = "blossom:d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c.jpg?xs=blossom.laantungir.net&xs=cdn.satellite.earth&xs=blossom.primal.net&as=1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139&sz=117475"
const bytes = new TextEncoder().encode("a picture")
const sha = createHash("sha256").update(bytes).digest("hex")
const link = (q = "") => `blossom:${sha}.png${q}`

test("parses the test post's link: sha256, extension, its three servers as https, author, size", () => {
  const b = parseBlossomUri(LINK)
  assert.equal(b.sha256, "d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c"); assert.equal(b.ext, "jpg")
  assert.deepEqual(b.servers, ["https://blossom.laantungir.net", "https://cdn.satellite.earth", "https://blossom.primal.net"])
  assert.equal(b.author, "1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139"); assert.equal(b.size, 117475)
  assert.equal(blossomKind(b), "image"); assert.equal(blossomKind(parseBlossomUri(`blossom:${sha}.mp4`)), "video")
  assert.equal(parseBlossomUri(`blossom:${sha.slice(1)}.jpg`), null, "not 64 hex")
  assert.equal(parseBlossomUri(`blossom:${sha}`), null, "no extension")
  assert.equal(parseBlossomUri(`https://x/${sha}.jpg`), null)
  assert.equal(parseBlossomUri(`blossom:${sha}.png?as=nothex&sz=-4`).author, null)
})

test("servers: https only, and never this machine or a private network", () => {
  assert.equal(serverOrigin("blossom.primal.net"), "https://blossom.primal.net")
  assert.equal(serverOrigin("https://laantungir.net/blossom/"), "https://laantungir.net/blossom")
  for (const bad of ["http://cdn.example", "http://127.0.0.1:9999", "https://127.0.0.1:9443", "localhost:3000", "https://192.168.4.99", "https://10.0.0.2", "https://172.20.1.1", "https://[::1]", "https://nas.local", "https://abc.onion", "https://user:pw@cdn.example", "intranet"])
    assert.equal(serverOrigin(bad), null, bad)
  const b = parseBlossomUri(link("?xs=one.example&xs=http://two.example&xs=127.0.0.1"))
  const list = candidateServers(b, ["https://laantungir.net/blossom", "http://127.0.0.1:9999", "https://one.example"], ["https://blossom.primal.net"])
  assert.deepEqual(list, ["https://one.example", "https://laantungir.net/blossom", "https://blossom.primal.net"], "the link's, the author's, the usual; once each")
  const many = candidateServers(parseBlossomUri(link(Array.from({ length: 12 }, (_, i) => `${i ? "&" : "?"}xs=s${i}.example`).join(""))))
  assert.equal(many.length, MAX_SERVERS)
})

const server = map => async url => {
  const host = new URL(url).origin
  const body = map[host]
  if (!body) return { ok: false, status: 404, headers: new Map(), arrayBuffer: async () => new ArrayBuffer(0) }
  return { ok: true, status: 200, headers: new Map([["content-type", "image/png"]]), arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) }
}

test("the bytes must hash to the link's sha256: a server sending other bytes is skipped", async () => {
  const b = parseBlossomUri(link())
  const asked = []
  const fetch = async (url, o) => { asked.push(url); return server({ "https://liar.example": new TextEncoder().encode("something else"), "https://good.example": bytes })(url, o) }
  const got = await fetchVerified(b, ["https://down.example", "https://liar.example", "https://good.example"], { fetch })
  assert.equal(got.server, "https://good.example"); assert.equal(got.mime, "image/png")
  assert.deepEqual(asked, [`https://down.example/${sha}.png`, `https://liar.example/${sha}.png`, `https://good.example/${sha}.png`], "GET <server>/<sha256>.<ext>")
  assert.equal(await fetchVerified(b, ["https://liar.example"], { fetch }), null, "no server with the right bytes: nothing")
  assert.equal(await fetchVerified(parseBlossomUri(link("?sz=999")), ["https://good.example"], { fetch, maxBytes: 100 }), null, "too large to check")
})

test("order: the link's servers first; then the author's 10063 list; then the usual servers", async () => {
  resetBlossom()
  const b = parseBlossomUri(link("?xs=empty.example&as=" + "a".repeat(64)))
  const asked = []
  const fetch = async (url, o) => { asked.push(new URL(url).origin); return server({ "https://usual.example": bytes })(url, o) }
  const query = async (relays, f) => { assert.deepEqual(f, { kinds: [10063], authors: ["a".repeat(64)] }); return [{ kind: 10063, pubkey: "a".repeat(64), created_at: 1, tags: [["server", "https://listed.example"], ["server", "http://127.0.0.1:9999"]] }] }
  const r = await loadBlossom(b, { relays: ["wss://r.example"], fetch, query, usual: ["https://usual.example"], makeUrl: () => "blob:x" })
  assert.deepEqual(r, { url: "blob:x", kind: "image", server: "https://usual.example" })
  assert.deepEqual(asked.slice(0, 2), ["https://empty.example", "https://listed.example"])
  assert.ok(!asked.includes("http://127.0.0.1:9999"))
  resetBlossom()
  const none = await loadBlossom(parseBlossomUri(link("?xs=empty.example")), { relays: [], fetch: server({}), usual: ["https://usual.example"], makeUrl: () => "blob:x" })
  assert.equal(none, null)
})

test("in a note: the link is its own media element, not text and not an https picture", () => {
  const vnode = NoteText({ content: `This is a test of BUD-10. Can you see this image?\n${LINK} nice`, tags: [], author: "1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139" })
  const kids = vnode.props.children[0]
  const blossom = kids.filter(k => k?.props?.b)
  assert.equal(blossom.length, 1); assert.equal(blossom[0].props.b.sha256, "d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c")
  assert.ok(!JSON.stringify(kids.filter(k => typeof k === "string")).includes("blossom:"), "no raw link in the text")
  assert.equal(vnode.props.children[1], false, "no https carousel for it")
})
