// The page's mesh port 80 (src/fips/mesh-door.js) against the real haven.wasm under node: a stranger gets only
// photos a public note names, with the apps' rules (haven-go mesh_door.go, mesh_safety.go, mesh_head.go).
// Skipped until tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { createHash, randomBytes } from "node:crypto"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { wrap } from "../src/haven/haven.js"
import { HavenClient } from "../src/haven/client.js"
import { MeshDoorServer } from "../src/fips/mesh-door.js"
import { MeshBlobClient } from "../src/fips/blob-get.js"
import { nodeFabric } from "./support/node-fabric.js"

const WASM = new URL("../public/haven.wasm", import.meta.url)
const SHIM = new URL("../src/haven/wasm_exec.js", import.meta.url)
const built = existsSync(WASM) && existsSync(SHIM)
const skip = !built && "public/haven.wasm not built"
const now = () => Math.floor(Date.now() / 1000)
const sha = b => createHash("sha256").update(b).digest("hex")

let haven
after(() => { if (haven) setImmediate(() => process.exit(process.exitCode ?? 0)) })
async function boot() {
  if (haven) return haven
  await import(SHIM.href)
  const go = new globalThis.Go()
  const { instance } = await WebAssembly.instantiate(readFileSync(WASM), go.importObject)
  go.run(instance)
  for (let i = 0; typeof globalThis.havenStart !== "function"; i++) {
    if (i > 3000) throw new Error("entry point never registered")
    await new Promise(r => setTimeout(r, 10))
  }
  return (haven = wrap(globalThis))
}

/** One HTTP/1.1 exchange over a havenConn stream: resolves to the whole response (status line, headers, body). */
function http(stream, head, body = new Uint8Array(0)) {
  return new Promise((resolve, reject) => {
    if (stream.error) return reject(new Error(stream.error))
    const parts = []
    stream.onData(b => parts.push(Buffer.from(b)))
    stream.onClose(() => resolve(Buffer.concat(parts)))
    stream.write(Buffer.concat([Buffer.from(head + "\r\n\r\n"), Buffer.from(body)]))
  })
}
const statusOf = res => Number(res.toString("latin1").split(" ")[1])

/** Owner-signed Blossom upload of bytes over the owner's own raw stream, as the app's uploads go. */
async function upload(h, sk, bytes) {
  const x = sha(bytes)
  const auth = finalizeEvent({ kind: 24242, created_at: now(), content: "upload", tags: [["t", "upload"], ["x", x], ["expiration", String(now() + 600)]] }, sk)
  const res = await http(h.conn(`up-${x.slice(0, 8)}`, { mode: "raw", owner: true }),
    `PUT /upload HTTP/1.1\r\nHost: haven\r\nAuthorization: Nostr ${Buffer.from(JSON.stringify(auth)).toString("base64")}\r\nContent-Type: image/jpeg\r\nContent-Length: ${bytes.length}\r\nConnection: close`, bytes)
  assert.equal(statusOf(res), 200, "owner upload: " + res.toString("latin1").slice(0, 200))
  return x
}

let n = 0
const meshReq = (h, line, extra = "") => http(h.conn(`mesh-t${n++}`, { mode: "mesh", peer: getPublicKey(generateSecretKey()) }), `${line} HTTP/1.1\r\nHost: page.fips\r\nConnection: close${extra}`)

/** A Haven with two photos stored: `posted` named by the owner's public note, `unposted` named by none. */
async function vaultWithPhotos(prefix) {
  const owner = generateSecretKey()
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(owner)), storePrefix: prefix })
  const posted = new Uint8Array(randomBytes(40_000)), unposted = new Uint8Array(randomBytes(30_000))
  const p = await upload(h, owner, posted), u = await upload(h, owner, unposted)
  const page = new HavenClient(h.conn(`page-${prefix}`, { mode: "nip01", route: "/", owner: true }))
  const ev = finalizeEvent({ kind: 1, created_at: now(), content: `look https://example.com/${p}.jpg`, tags: [["imeta", `url https://example.com/${p}.jpg`, `x ${p}`]] }, owner)
  assert.equal((await page.event(ev)).ok, true)
  return { h, owner, page, posted, unposted, p, u }
}

test("real Haven mesh door: a stranger reads a posted photo, gets 404 for an unposted one (GET and HEAD)", { skip }, async () => {
  const v = await vaultWithPhotos("door-a")
  try {
    const got = await meshReq(v.h, `GET /${v.p}`)
    assert.equal(statusOf(got), 200)
    assert.equal(sha(got.subarray(got.indexOf("\r\n\r\n") + 4)), v.p, "the posted photo's exact bytes")
    assert.equal(statusOf(await meshReq(v.h, `GET /${v.u}`)), 404, "an unposted photo is not readable by hash")
    assert.equal(statusOf(await meshReq(v.h, `HEAD /${v.p}`)), 200)
    // #1050: HEAD follows GET's rule, and answers like a missing blob, so it is no yes/no oracle.
    assert.equal(statusOf(await meshReq(v.h, `HEAD /${v.u}`)), 404)
    assert.equal(statusOf(await meshReq(v.h, `HEAD /${"c".repeat(64)}`)), 404)
    // Nothing else on the door: no other routes, no relay info, no uploads without the owner's signature.
    assert.equal(statusOf(await meshReq(v.h, "GET /private")), 404)
    assert.equal(statusOf(await meshReq(v.h, "GET /", "\r\nAccept: application/nostr+json")), 404)
    assert.equal(statusOf(await meshReq(v.h, "PUT /upload", "\r\nContent-Length: 3")), 401)
  } finally {
    v.page.close()
    await v.h.stop()
  }
})

test("real Haven: a mesh stream is never the owner's, and the mode exists", { skip }, async () => {
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(generateSecretKey())), storePrefix: "door-b" })
  try {
    assert.match(h.conn("m-owner", { mode: "mesh", owner: true }).error ?? "", /never the owner's/)
    assert.equal(h.conn("m-ok", { mode: "mesh", peer: "x" }).error, undefined)
  } finally {
    await h.stop()
  }
})

test("page port 80 over FIPS: a stranger's read gets the posted photo, not the unposted one", { skip }, async () => {
  const v = await vaultWithPhotos("door-c")
  const net = nodeFabric()
  const pageKey = "02" + getPublicKey(generateSecretKey()), strangerKey = "02" + getPublicKey(generateSecretKey())
  const door = new MeshDoorServer(net.node(pageKey), pageKey, v.h)
  const reader = new MeshBlobClient(net.node(strangerKey), strangerKey, { allow: () => true })
  const timer = setInterval(async () => { await net.deliver(); await door.tick() }, 2)
  try {
    const got = await reader.get(pageKey, v.p, { timeoutMs: 20_000 })
    assert.equal(sha(got.bytes), v.p)
    await assert.rejects(reader.get(pageKey, v.u, { timeoutMs: 20_000 }), /answered 404/)
    assert.equal(door.stats.accepted, 2)
  } finally {
    clearInterval(timer)
    await reader.stop()
    await door.stop()
    v.page.close()
    await v.h.stop()
  }
})

// Both on one node: the page's own door listens on 80 while its client reads a vault's 80. Each shim endpoint takes
// only its own segments; otherwise the door answers the vault's replies with an RST and the read dies.
test("a page serving its door still reads photos from its vault's port 80, and the door still takes SYNs", async () => {
  const { meshHttpVault } = await import("../tools/lib/mesh-http-vault.js")
  const net = nodeFabric()
  const pageKey = "02" + getPublicKey(generateSecretKey()), vaultKey = "02" + getPublicKey(generateSecretKey())
  const bytes = new Uint8Array(randomBytes(20_000)), h = sha(bytes)
  const vault = meshHttpVault(net.node(vaultKey), vaultKey, new Map([[h, { bytes, type: "image/jpeg" }]]))
  const pageNode = net.node(pageKey)
  const opened = []
  const stub = { conn: (id, opts) => (opened.push(opts), { onData() {}, onClose() {}, write() {}, close() {}, buffered: () => 0 }) }
  const door = new MeshDoorServer(pageNode, pageKey, stub)
  const reader = new MeshBlobClient(pageNode, pageKey, { allow: k => String(k).endsWith(vaultKey.slice(2)) })
  const timer = setInterval(async () => { await net.deliver(); await vault.tick(); await door.tick() }, 2)
  try {
    const got = await reader.get(vaultKey, h, { timeoutMs: 10_000 })
    assert.equal(sha(got.bytes), h)
    assert.equal(door.stats.accepted, 0, "the vault's replies never reached the door")
    // A stranger dials the page's 80 from a client endpoint (the stand-in vault only listens).
    const { FipsTcpEndpoint } = await import("@fips/tcp")
    const { ipv6ShimEndpoint } = await import("../src/fips/ipv6-shim.js")
    const strangerKey = "02" + getPublicKey(generateSecretKey())
    const dialer = new FipsTcpEndpoint(ipv6ShimEndpoint(net.node(strangerKey), strangerKey, { allow: () => true }), 80)
    await dialer.connect(pageKey, Date.now())
    for (let i = 0; i < 100 && !door.stats.accepted; i++) { await dialer.poll(Date.now()); await new Promise(r => setTimeout(r, 10)) }
    assert.equal(door.stats.accepted, 1, "a SYN to the page's 80 reaches the door")
    assert.equal(opened[0].mode, "mesh")
    assert.equal(opened[0].peer, strangerKey.slice(2))
  } finally {
    clearInterval(timer)
    await reader.stop()
    await door.stop()
    await vault.stop()
  }
})
