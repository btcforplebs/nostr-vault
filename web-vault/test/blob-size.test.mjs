// Vault › Media list (net/blob-size.js, Z1): a row with no size asks its server once with HEAD; the answer is kept
// by hash, and a failed or sizeless answer is asked again.
import test from "node:test"
import assert from "node:assert/strict"
import { blobSizes, sizeFromHead } from "../src/net/blob-size.js"

const sha = "ab".repeat(32)
const url = `https://blossom.example/${sha}.jpg`
const memory = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) } }
const reply = (status, length) => ({ status, headers: { get: h => (h === "Content-Length" ? length : null) } })
const tick = () => new Promise(r => setTimeout(r, 5))

test("only a plain 200 with a length gives a size", () => {
  assert.equal(sizeFromHead(200, "2457600"), 2457600)
  assert.equal(sizeFromHead(200, " 12 "), 12)
  assert.equal(sizeFromHead(206, "1"), null)
  assert.equal(sizeFromHead(404, "153"), null)
  assert.equal(sizeFromHead(200, null), null)
  assert.equal(sizeFromHead(200, "0"), null)
  assert.equal(sizeFromHead(200, "-5"), null)
  assert.equal(sizeFromHead(200, "12abc"), null)
})

test("one HEAD per hash, then the kept answer, also after a reload", async () => {
  const storage = memory(), asked = []
  const fetch = async (u, o) => { asked.push([u, o.method]); await tick(); return reply(200, "999") }
  const s = blobSizes({ storage, fetch })
  assert.deepEqual(await Promise.all([1, 2, 3].map(() => s.size(sha.toUpperCase(), url))), [999, 999, 999])
  assert.equal(await s.size(sha, url), 999)
  assert.deepEqual(asked, [[url, "HEAD"]])
  await tick()
  const again = blobSizes({ storage, fetch: async () => { throw new Error("should not ask") } })
  assert.equal(again.cached(sha), 999)
  assert.equal(await again.size(sha, url), 999)
})

test("a failed or sizeless answer is not kept", async () => {
  const replies = [() => { throw new Error("down") }, () => reply(200, null), () => reply(206, "1"), () => reply(200, "50")]
  let n = 0
  const s = blobSizes({ storage: memory(), fetch: async () => replies[n++]() })
  for (let i = 0; i < 3; i++) assert.equal(await s.size(sha, url), null)
  assert.equal(await s.size(sha, url), 50)
  assert.equal(n, 4)
})

test("bad hashes and non-http links are never asked", async () => {
  let n = 0
  const s = blobSizes({ storage: memory(), fetch: async () => { n++; return reply(200, "1") } })
  assert.equal(await s.size("nothex", url), null)
  assert.equal(await s.size(sha, `blossom:${sha}.jpg`), null)
  assert.equal(n, 0)
})

test("keeps the newest `max` hashes", async () => {
  const s = blobSizes({ storage: memory(), fetch: async () => reply(200, "7"), max: 2 })
  const h = i => String(i).repeat(64)
  for (const i of [1, 2, 3]) await s.size(h(i), url)
  assert.equal(s.cached(h(1)), null)
  assert.equal(s.cached(h(3)), 7)
})

test("the list sorts a learned size like a listed one, and a row shows it", async () => {
  const { registerHooks } = await import("node:module")
  const { readFileSync } = await import("node:fs")
  const { fileURLToPath } = await import("node:url")
  const { transformSync } = await import("rolldown/utils")
  registerHooks({
    load(u, context, next) {
      if (u.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
      if (!u.endsWith(".jsx")) return next(u, context)
      const path = fileURLToPath(u)
      return { format: "module", source: transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } }).code, shortCircuit: true }
    },
  })
  const { withLearnedSizes, sections } = await import("../src/screens/BlossomGallery.jsx")
  const store = blobSizes({ storage: memory(), fetch: async () => reply(200, "5000") })
  await store.size(sha, url)
  const files = [{ sha256: sha, url, kind: "photo", size: 0, uploaded: 1, servers: [] }, { sha256: "cd".repeat(32), url, kind: "photo", size: 100, uploaded: 2, servers: [] }]
  const learned = withLearnedSizes(files, store)
  assert.equal(learned[0].size, 5000)
  assert.equal(files[0].size, 0, "the listed file is not changed")
  assert.deepEqual(sections(learned, "largest", "en-US")[0].blobs.map(b => b.size), [5000, 100])
})
