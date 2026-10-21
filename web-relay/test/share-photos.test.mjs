// The public post page's mesh photo script: a photo the page marked (data-x, data-vaults) is read over FIPS when its
// https server fails, from the vaults the page named and no others; the reader starts once, and only when needed.
// A tiny fake document; the last test reads through the real photo-only reader over a datagram fabric.
import { test } from "node:test"
import assert from "node:assert/strict"
import { randomBytes, createHash } from "node:crypto"
import { toHex } from "@fips/core"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { meshTarget, wireMeshPhotos } from "../src/fips/share-photos.js"
import { startPhotoReader, throwawayIdentity } from "../src/fips/photo-reader.js"
import { meshHttpVault } from "../tools/lib/mesh-http-vault.js"
import { nodeFabric } from "./support/node-fabric.js"

const sha = b => createHash("sha256").update(b).digest("hex")
const HASH = "e4".repeat(32), V1 = "11".repeat(32), V2 = "22".repeat(32)

function img({ x = HASH, vaults = `${V1},${V2}`, failed = false } = {}) {
  const link = { href: "https://media.example/dead.png" }
  const listeners = {}
  return {
    dataset: { ...(x && { x }), ...(vaults && { vaults }) },
    complete: failed, naturalWidth: 0, src: "https://media.example/dead.png", link,
    closest: sel => (sel === "a" ? link : null),
    addEventListener: (type, fn) => { listeners[type] = fn },
    fail: () => listeners.error?.(),
  }
}
const doc = imgs => ({ querySelectorAll: sel => (sel === "img[data-x][data-vaults]" ? imgs.filter(i => i.dataset.x && i.dataset.vaults) : []) })
const settle = () => new Promise(r => setTimeout(r, 5))

function fakeReader(has) {
  const calls = { starts: 0, gets: [], allowed: [] }
  const start = async getPhotoVaults => {
    calls.starts++
    return { getBlob: async (vault, x) => {
      calls.gets.push(vault); calls.allowed.push([...getPhotoVaults()])
      if (!has.includes(vault)) throw new Error("no route")
      return { bytes: new Uint8Array([1, 2, 3]), type: "image/png" }
    } }
  }
  return { calls, start, toUrl: (b, t) => `blob:${t}:${b.length}` }
}

test("meshTarget: a 64-hex hash and up to three 64-hex vaults, else nothing", () => {
  assert.deepEqual(meshTarget(img()), { x: HASH, vaults: [V1, V2] })
  assert.equal(meshTarget(img({ vaults: "nothex" })), undefined)
  assert.equal(meshTarget(img({ x: "abc" })), undefined)
  assert.equal(meshTarget(img({ vaults: [V1, V2, "33".repeat(32), "44".repeat(32)].join(",") })).vaults.length, 3)
})

test("a photo that already failed reads now; the next vault is tried; the link opens what loaded", async () => {
  const f = fakeReader([V2]), a = img({ failed: true })
  await wireMeshPhotos(doc([a]), f)
  assert.deepEqual(f.calls.gets, [V1, V2])
  assert.equal(a.src, "blob:image/png:3")
  assert.equal(a.link.href, a.src)
  assert.equal(a.dataset.mesh, "loaded")
  assert.deepEqual(f.calls.allowed[0].sort(), [V1, V2].sort(), "the reader may ask only the vaults the page named")
})

test("a photo still loading waits for its error; a photo that loads never starts the reader", async () => {
  const f = fakeReader([V1]), loading = img(), fine = img()
  await wireMeshPhotos(doc([loading, fine]), f)
  assert.equal(f.calls.starts, 0, "nothing failed yet: no reader")
  loading.fail(); await settle()
  assert.equal(f.calls.starts, 1)
  assert.equal(loading.src, "blob:image/png:3")
  assert.equal(fine.src, "https://media.example/dead.png")
})

test("one reader for the page; a photo no vault has is marked failed and keeps its link", async () => {
  const f = fakeReader([]), a = img({ failed: true }), b = img({ failed: true, x: "f0".repeat(32) })
  await wireMeshPhotos(doc([a, b]), f)
  assert.equal(f.calls.starts, 1)
  assert.equal(a.dataset.mesh, "failed")
  assert.equal(a.link.href, "https://media.example/dead.png")
})

test("an unmarked photo is never read", async () => {
  const f = fakeReader([V1]), a = img({ failed: true, vaults: "" })
  await wireMeshPhotos(doc([a]), f)
  assert.equal(f.calls.starts, 0)
})

test("end to end: the real photo-only reader fetches the blob, hash-checked, from the named vault", async () => {
  const net = nodeFabric()
  const bytes = new Uint8Array(randomBytes(30_000)), h = sha(bytes)
  const vaultKey = "02" + getPublicKey(generateSecretKey())
  const vault = meshHttpVault(net.node(vaultKey), vaultKey, new Map([[h, { bytes, type: "image/jpeg" }]]))
  const timer = setInterval(async () => { await net.deliver(); await vault.tick() }, 2)
  let reader
  try {
    const identity = await throwawayIdentity()
    const start = async getPhotoVaults => (reader = await startPhotoReader({ getPhotoVaults, identity,
      makeNode: id => ({ ...net.node("02" + toHex(id.xOnlyPubkey)), start: async () => {}, stop: async () => {} }) }))
    let got
    const a = img({ failed: true, x: h, vaults: vaultKey.slice(2) })
    await wireMeshPhotos(doc([a]), { start, toUrl: (b, t) => { got = { b, t }; return "blob:ok" }, timeoutMs: 20_000 })
    assert.equal(a.src, "blob:ok")
    assert.equal(sha(got.b), h)
    assert.equal(got.t, "image/jpeg")
    assert.equal(vault.stats.served, 1)
  } finally { clearInterval(timer); await reader?.stop(); await vault.stop() }
})
