import test from "node:test"
import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { hashOfLink, otherServers, checkLinks, deadLinks, MAX_EMOJI_BYTES } from "../src/net/emoji-links.js"

const bytes = new TextEncoder().encode("emoji image")
const sha = createHash("sha256").update(bytes).digest("hex")
const res = (body, ok = true) => ({ ok, headers: { get: () => null }, arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) })

test("hash from a Blossom link; other links have none", () => {
  assert.deepEqual(hashOfLink(`https://cdn.example/${sha.toUpperCase()}.GIF`), { sha256: sha, ext: "gif" })
  assert.deepEqual(hashOfLink(`https://cdn.example/${sha}`), { sha256: sha, ext: "png" })
  assert.equal(hashOfLink("https://cdn.example/party.gif"), null)
  assert.equal(hashOfLink("not a url"), null)
})

test("other servers: https only, never the dead link's host, each once", () => {
  assert.deepEqual(otherServers(`https://dead.example/${sha}.png`, [["https://dead.example", "https://a.example/"], ["a.example", "http://plain.example", "https://b.example"]]),
    ["https://a.example", "https://b.example"])
})

test("check: ok, moved (hash checked), dead", async () => {
  const live = "https://ok.example/a.png", gone = `https://dead.example/${sha}.png`, lost = "https://dead.example/plain.png", wrong = `https://dead.example/${"0".repeat(64)}.png`
  const fetched = []
  const fetch = async url => { fetched.push(url); return url.startsWith("https://good.example/") ? res(bytes) : res(new Uint8Array(), false) }
  const seen = []
  const out = await checkLinks([live, gone, lost, wrong, live], {
    probe: async u => u === live, fetch, servers: async () => [["https://bad.example", "https://good.example"]], onResult: u => seen.push(u) })
  assert.equal(out.get(live), "ok")
  assert.deepEqual(out.get(gone), { moved: `https://good.example/${sha}.png` })
  assert.equal(out.get(lost), "dead", "no hash in the link: nothing to look for")
  assert.equal(out.get(wrong), "dead", "bytes that don't match the hash are not a copy")
  assert.equal(seen.length, 4, "each link once")
  assert.ok(!fetched.some(u => u.startsWith("https://dead.example")))
})

test("a copy over the emoji cap is not used", async () => {
  const big = new Uint8Array(MAX_EMOJI_BYTES + 1)
  const h = createHash("sha256").update(big).digest("hex")
  const out = await checkLinks([`https://dead.example/${h}.png`], { probe: async () => false, fetch: async () => res(big), servers: async () => [["https://good.example"]] })
  assert.equal(out.get(`https://dead.example/${h}.png`), "dead")
})

test("dead links section lists dead emoji per set, saved ones marked", () => {
  const set = { address: "s", emoji: [{ code: "a", url: "https://x/a" }, { code: "b", url: "https://x/b" }, { code: "c", url: "https://x/c" }] }
  const states = new Map([["https://x/a", "dead"], ["https://x/b", "ok"], ["https://x/c", "dead"]])
  const out = deadLinks([set], states, (_s, e) => (e.code === "c" ? {} : null))
  assert.deepEqual(out.map(d => [d.code, d.saved]), [["a", false], ["c", true]])
})

test("a server with no Content-Length is cut off once past the cap, not read to the end (Tron S1)", async () => {
  let pulled = 0, cancelled = false
  const endless = { getReader: () => ({ read: async () => { pulled++; return { done: false, value: new Uint8Array(512 * 1024) } }, cancel: async () => { cancelled = true } }) }
  const url = `https://dead.example/${sha}.png`
  const out = await checkLinks([url], { probe: async () => false, servers: async () => [["https://evil.example"]],
    fetch: async () => ({ ok: true, headers: { get: () => null }, body: endless, arrayBuffer: async () => { throw new Error("must not buffer whole") } }) })
  assert.equal(out.get(url), "dead")
  assert.ok(cancelled, "stream cancelled")
  assert.ok(pulled <= 5, `stopped after the cap (${pulled} chunks)`)
})

test("a streamed body under the cap is read whole and hash-checked", async () => {
  const chunks = [bytes.slice(0, 4), bytes.slice(4)]
  const body = { getReader: () => ({ read: async () => (chunks.length ? { done: false, value: chunks.shift() } : { done: true }), cancel: async () => {} }) }
  const url = `https://dead.example/${sha}.png`
  const out = await checkLinks([url], { probe: async () => false, servers: async () => [["https://good.example"]], fetch: async () => ({ ok: true, headers: { get: () => null }, body }) })
  assert.deepEqual(out.get(url), { moved: `https://good.example/${sha}.png` })
})
