// Blob reads over mesh port 80: the IPv6 shim translation (ipv6-shim.js) and the HTTP client on top of it
// (blob-get.js), against a stand-in vault (tools/lib/mesh-http-vault.js) on an in-memory fabric. Run: node --test test/
import { test } from "node:test"
import assert from "node:assert/strict"
import { randomBytes, createHash } from "node:crypto"
import { FlagSet, Flags, Segment, TcpOptionKind } from "@fips/tcp"
import { deriveNodeAddr } from "@fips/core"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { meshAddress, tcpChecksum, encodeShim, decodeShim } from "../src/fips/ipv6-shim.js"
import { MeshBlobClient, parseBlobRef, parseHead, dechunk } from "../src/fips/blob-get.js"
import { meshHttpVault } from "../tools/lib/mesh-http-vault.js"
import { nodeFabric } from "./support/node-fabric.js"

const key = () => "02" + getPublicKey(generateSecretKey())
const sha = b => createHash("sha256").update(b).digest("hex")
const hex = b => Buffer.from(b).toString("hex")

test("mesh address is fd + the node address, as fips FipsAddress::from_node_addr", () => {
  const k = key()
  const want = Buffer.concat([Buffer.from([0xfd]), Buffer.from(deriveNodeAddr(Buffer.from(k, "hex"))).subarray(0, 15)])
  assert.equal(hex(meshAddress(k)), want.toString("hex"))
  assert.equal(hex(meshAddress(k.slice(2))), want.toString("hex"))
  assert.equal(hex(meshAddress(npubEncode(k.slice(2)))), want.toString("hex"))
})

test("checksum: the RFC 1071 sum over pseudo-header + segment folds to 0xffff", () => {
  const src = meshAddress(key()), dst = meshAddress(key())
  for (const len of [20, 21, 1043]) {
    const seg = new Uint8Array(randomBytes(len))
    seg[12] = 0x50
    const c = tcpChecksum(seg, src, dst)
    seg[16] = c >> 8; seg[17] = c & 0xff
    let sum = 0
    const words = [...src, ...dst, 0, 0, len >> 8, len & 0xff, 0, 0, 0, 6, ...seg, ...(len % 2 ? [0] : [])]
    for (let i = 0; i < words.length; i += 2) sum += (words[i] << 8) | words[i + 1]
    while (sum > 0xffff) sum = (sum & 0xffff) + (sum >>> 16)
    assert.equal(sum, 0xffff, `len ${len}`)
  }
})

test("a TCP/FIPS SYN goes out as a plain TCP SYN: MSS kept, version option gone, valid checksum", () => {
  const src = meshAddress(key()), dst = meshAddress(key())
  // The SYN @fips/tcp builds (src/segment.js buildSegment): MSS, then the TCP/FIPS version option.
  const syn = new Segment({ srcPort: 49152, dstPort: 80, seq: 1234, flags: new FlagSet(Flags.Syn), options: [
    { kind: TcpOptionKind.MaxSegmentSize, value: 1024 }, { kind: TcpOptionKind.FipsVersion, version: 1, reserved: 0 }] }).encode()
  assert.ok(Segment.decode(syn).supportsFipsVersion(1), "control: @fips/tcp puts the version option on a SYN")
  const shim = encodeShim(syn, src, dst)
  assert.deepEqual([...shim.subarray(0, 7)], [0, 0x60, 0, 0, 0, 6, 64])
  const wire = shim.subarray(7)
  assert.equal(wire[12] >> 4, 6, "20-byte header + one 4-byte MSS option")
  assert.deepEqual([...wire.subarray(20, 24)], [2, 4, 1024 >> 8, 1024 & 0xff])
  assert.equal((wire[16] << 8) | wire[17], tcpChecksum(wire, src, dst))
  const back = decodeShim(shim, src, dst)
  assert.ok(Segment.decode(back).supportsFipsVersion(1), "a received SYN gets the version option back")
  assert.equal(decodeShim(shim, meshAddress(key()), dst), undefined, "a segment from another address fails the checksum")
})

test("inbound: bad checksum, URG, and non-TCP are dropped; smoltcp-style options reduce to MSS", () => {
  const src = meshAddress(key()), dst = meshAddress(key())
  // A SYN-ACK as smoltcp might send it: MSS, window scale, SACK permitted, timestamps.
  const opts = [2, 4, 0x04, 0xc4, 1, 3, 3, 7, 4, 2, 8, 10, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
  const hdr = 20 + Math.ceil(opts.length / 4) * 4
  const seg = new Uint8Array(hdr + 5)
  const v = new DataView(seg.buffer)
  v.setUint16(0, 80); v.setUint16(2, 49152); v.setUint32(4, 777); v.setUint32(8, 1235)
  seg[12] = (hdr / 4) << 4; seg[13] = 0x12; v.setUint16(14, 64000)
  seg.set(opts, 20); seg.set([1, 2, 3, 4, 5], hdr)
  const c = tcpChecksum(seg, src, dst); seg[16] = c >> 8; seg[17] = c & 0xff
  const shim = new Uint8Array([0, 0x60, 0, 0, 0, 6, 64, ...seg])
  const out = Segment.decode(decodeShim(shim, src, dst))
  assert.equal(out.maxSegmentSize(), 1220)
  assert.ok(out.supportsFipsVersion(1))
  assert.equal(out.options.length, 2, "only MSS + version")
  assert.deepEqual([...out.payload], [1, 2, 3, 4, 5])
  assert.equal(out.seq, 777)
  assert.equal(out.ack, 1235)
  const flipped = shim.slice(); flipped[flipped.length - 1] ^= 1
  assert.equal(decodeShim(flipped, src, dst), undefined, "one flipped payload bit")
  const urg = shim.slice(); urg[7 + 13] |= 0x20
  assert.equal(decodeShim(urg, src, dst), undefined, "URG")
  const udp = shim.slice(); udp[5] = 17
  assert.equal(decodeShim(udp, src, dst), undefined, "next header UDP")
})

test("parseBlobRef: bare hash, hash.ext, and the NIP-F1 .fips link", () => {
  const h = "a".repeat(64), k = getPublicKey(generateSecretKey())
  assert.deepEqual(parseBlobRef(h), { sha256: h })
  assert.deepEqual(parseBlobRef(h.toUpperCase() + ".jpg"), { sha256: h })
  assert.deepEqual(parseBlobRef(`http://${npubEncode(k)}.fips/${h}.png`), { sha256: h, vault: k })
  assert.throws(() => parseBlobRef(`https://${npubEncode(k)}.fips/${h}`))
  assert.throws(() => parseBlobRef(`http://example.com/${h}`))
  assert.throws(() => parseBlobRef("nope"))
})

test("parseHead and dechunk", () => {
  const enc = s => new TextEncoder().encode(s)
  assert.equal(parseHead(enc("HTTP/1.1 200 OK\r\nContent-Le")), undefined)
  const h = parseHead(enc("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nabc"))
  assert.equal(h.status, 200)
  assert.equal(h.headers.get("content-type"), "image/png")
  assert.equal(new TextDecoder().decode(enc("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nabc").subarray(h.bodyStart)), "abc")
  assert.throws(() => parseHead(enc("SSH-2.0\r\n\r\n")))
  assert.equal(dechunk(enc("3\r\nabc\r\n2\r\nde")), undefined)
  assert.equal(new TextDecoder().decode(dechunk(enc("3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n"))), "abcde")
})

async function setup({ loss = 0, chunked = false, blobs = new Map(), allowVault = true } = {}) {
  const net = nodeFabric(loss)
  const pageKey = key(), vaultKey = key()
  const vault = meshHttpVault(net.node(vaultKey), vaultKey, blobs, { chunked })
  const allowed = new Set(allowVault ? [vaultKey.slice(2)] : [])
  const client = new MeshBlobClient(net.node(pageKey), pageKey, { allow: k => allowed.has(String(k).slice(-64)) })
  let tamper
  const timer = setInterval(async () => { await net.deliver(tamper); await vault.tick() }, 2)
  return { net, vault, client, vaultKey, pageKey, setTamper: t => (tamper = t), stop: async () => { clearInterval(timer); await client.stop(); await vault.stop() } }
}

const blob = (n, type = "image/jpeg") => { const bytes = new Uint8Array(randomBytes(n)); return [sha(bytes), { bytes, type }] }

test("GET /<sha256>: the bytes come back and hash to what was asked (Content-Length)", async () => {
  const [h, b] = blob(300_000)
  const t = await setup({ blobs: new Map([[h, b]]) })
  try {
    const got = await t.client.get(t.vaultKey, h, { timeoutMs: 20_000 })
    assert.equal(sha(got.bytes), h)
    assert.equal(got.bytes.length, 300_000)
    assert.equal(got.type, "image/jpeg")
    assert.equal(t.vault.stats.served, 1)
  } finally { await t.stop() }
})

test("chunked response, from an npub, two reads at once", async () => {
  const [h1, b1] = blob(50_000), [h2, b2] = blob(9_001, "image/png")
  const t = await setup({ chunked: true, blobs: new Map([[h1, b1], [h2, b2]]) })
  try {
    const [g1, g2] = await Promise.all([t.client.get(npubEncode(t.vaultKey.slice(2)), h1), t.client.get(t.vaultKey, h2)])
    assert.equal(sha(g1.bytes), h1)
    assert.equal(sha(g2.bytes), h2)
    assert.equal(g2.type, "image/png")
  } finally { await t.stop() }
})

test("5% datagram loss: retransmission still delivers the exact bytes", async () => {
  const [h, b] = blob(120_000)
  const t = await setup({ loss: 0.05, blobs: new Map([[h, b]]) })
  try {
    const got = await t.client.get(t.vaultKey, h, { timeoutMs: 60_000 })
    assert.equal(sha(got.bytes), h)
  } finally { await t.stop() }
})

test("refusals: 404, a vault serving other bytes, a vault that isn't ours, a bad hash", async () => {
  const [h, b] = blob(1000)
  const [, other] = blob(1000)
  const t = await setup({ blobs: new Map([[h, other]]) })
  try {
    await assert.rejects(t.client.get(t.vaultKey, "b".repeat(64)), /answered 404/)
    await assert.rejects(t.client.get(t.vaultKey, h), /hash mismatch/)
    await assert.rejects(t.client.get(key(), h), /not one of this relay's vaults/)
    await assert.rejects(t.client.get(t.vaultKey, "xyz"), /not a sha256/)
    assert.equal(t.client.stats.failed, 2, "the last two are refused before any connection")
  } finally { await t.stop() }
  void b
})

test("segments from a stranger never reach the TCP stack", async () => {
  const [h, b] = blob(2000)
  const t = await setup({ blobs: new Map([[h, b]]) })
  try {
    // Re-label every datagram the vault sends as coming from a stranger key: the client must drop them all.
    const stranger = key()
    t.setTamper(d => (d.src === t.vaultKey ? { ...d, src: stranger } : d))
    await assert.rejects(t.client.get(t.vaultKey, h, { timeoutMs: 1500 }), /timed out/)
    assert.ok(t.client.stats.dropped > 0, "the SYN-ACKs were dropped")
    t.setTamper(undefined)
    const got = await t.client.get(t.vaultKey, h)
    assert.equal(sha(got.bytes), h, "control: the same read with the true source works")
  } finally { await t.stop() }
})

test("a client-only endpoint never accepts a SYN", async () => {
  const net = nodeFabric()
  const pageKey = key(), otherKey = key()
  const client = new MeshBlobClient(net.node(pageKey), pageKey, { allow: () => true })
  const other = meshHttpVault(net.node(otherKey), otherKey, new Map())
  try {
    // The other side tries to connect to the page's port 80.
    await other.tcp.connect(pageKey)
    await net.deliver()
    assert.equal(client.stats.dropped, 1)
    assert.equal(await client.tcp.accept(), undefined)
  } finally { await client.stop(); await other.stop() }
})

test("no route yet: the read retries inside its deadline, and gives up at it", async () => {
  const [h, b] = blob(5000)
  const net = nodeFabric()
  const pageKey = key(), vaultKey = key()
  const vault = meshHttpVault(net.node(vaultKey), vaultKey, new Map([[h, b]]))
  const real = net.node(pageKey)
  let failures = 2
  // The seed lookup fails the first two sends, the way @fips/core reports a route it can't find yet.
  const flaky = { on: real.on, sendDatagram: async a => { if (failures > 0) { failures--; throw new Error("no route to 0123") } return real.sendDatagram(a) } }
  const client = new MeshBlobClient(flaky, pageKey, { allow: () => true })
  const timer = setInterval(async () => { await net.deliver(); await vault.tick() }, 2)
  try {
    const got = await client.get(vaultKey, h, { timeoutMs: 10_000 })
    assert.equal(sha(got.bytes), h)
    assert.equal(client.stats.retries, 2)
    failures = Infinity
    await assert.rejects(client.get(vaultKey, h, { timeoutMs: 2_500 }), /no route/)
  } finally { clearInterval(timer); await client.stop(); await vault.stop() }
})

test("a vault key reported with odd parity (a session the vault opened) still matches the dialed stream", async () => {
  const [h, b] = blob(20_000)
  const t = await setup({ blobs: new Map([[h, b]]) })
  try {
    // @fips/core reports the remote key with its real prefix when the vault was the session initiator.
    t.setTamper(d => (d.src === t.vaultKey ? { ...d, src: "03" + t.vaultKey.slice(2) } : d))
    const got = await t.client.get(t.vaultKey, h, { timeoutMs: 5_000 })
    assert.equal(sha(got.bytes), h)
  } finally { await t.stop() }
})

test("only raster image and video types survive; svg and html come back as octet-stream", async () => {
  const [h1, b1] = blob(3000, "image/svg+xml"), [h2, b2] = blob(3000, "text/html"), [h3, b3] = blob(3000, "image/webp")
  const t = await setup({ blobs: new Map([[h1, b1], [h2, b2], [h3, b3]]) })
  try {
    assert.equal((await t.client.get(t.vaultKey, h1)).type, "application/octet-stream")
    assert.equal((await t.client.get(t.vaultKey, h2)).type, "application/octet-stream")
    assert.equal((await t.client.get(t.vaultKey, h3)).type, "image/webp", "control: a raster type is kept")
  } finally { await t.stop() }
})

test("an aborted read resets at once (AbortError, not the timeout); a finished one says when its stream is closed", async () => {
  const [h, b] = blob(2000)
  const t = await setup({ blobs: new Map([[h, b]]) })
  try {
    t.setTamper(d => (d.src === t.vaultKey ? { ...d, src: key() } : d)) // the vault never answers
    const c = new AbortController(), t0 = Date.now()
    setTimeout(() => c.abort(), 300)
    await assert.rejects(t.client.get(t.vaultKey, h, { timeoutMs: 30_000, signal: c.signal }), e => e.name === "AbortError")
    assert.ok(Date.now() - t0 < 5_000, "well before the 30 s timeout")
    await assert.rejects(t.client.get(t.vaultKey, h, { signal: AbortSignal.abort() }), e => e.name === "AbortError")
    t.setTamper(undefined)
    const got = await t.client.get(t.vaultKey, h)
    assert.equal(sha(got.bytes), h)
    await got.closed
  } finally { await t.stop() }
})
