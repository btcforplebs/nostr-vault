// The photo-only reader: with no owner and no Haven it reads by hash from the vaults it is allowed, and nothing else.
import { test } from "node:test"
import assert from "node:assert/strict"
import { randomBytes, createHash } from "node:crypto"
import { toHex } from "@fips/core"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { startPhotoReader, throwawayIdentity } from "../src/fips/photo-reader.js"
import { meshHttpVault } from "../tools/lib/mesh-http-vault.js"
import { nodeFabric } from "./support/node-fabric.js"

const sha = b => createHash("sha256").update(b).digest("hex")
const key = () => "02" + getPublicKey(generateSecretKey())

async function setup() {
  const net = nodeFabric()
  const bytes = new Uint8Array(randomBytes(40_000)), h = sha(bytes)
  const blobKey = key(), mainKey = key()
  const blob = meshHttpVault(net.node(blobKey), blobKey, new Map([[h, { bytes, type: "image/jpeg" }]]))
  const main = meshHttpVault(net.node(mainKey), mainKey, new Map([[h, { bytes, type: "image/jpeg" }]]))
  const photoVaults = new Set([blobKey.slice(2)])
  let started = 0, stopped = 0
  const identity = await throwawayIdentity()
  const reader = await startPhotoReader({
    getPhotoVaults: () => photoVaults,
    identity,
    // FIPS names a node by its even-parity compressed key; a fresh identity may be odd-parity.
    makeNode: id => ({ ...net.node("02" + toHex(id.xOnlyPubkey)), start: async () => started++, stop: async () => stopped++ }),
  })
  const timer = setInterval(async () => { await net.deliver(); await blob.tick(); await main.tick() }, 2)
  return { h, bytes, blobKey, mainKey, blob, main, reader, identity, counts: () => ({ started, stopped }),
    stop: async () => { clearInterval(timer); await reader.stop(); await blob.stop(); await main.stop() } }
}

test("reads a photo from an allowed vault, with no owner, Haven or storage", async () => {
  const t = await setup()
  try {
    const got = await t.reader.getBlob(t.blobKey, t.h, { timeoutMs: 20_000 })
    assert.equal(sha(got.bytes), t.h)
    assert.equal(t.blob.stats.served, 1)
    assert.equal(t.reader.status.photoOnly, true)
    assert.deepEqual(t.counts(), { started: 1, stopped: 0 })
  } finally { await t.stop() }
})

test("never asks a vault it is not allowed, even with the hash", async () => {
  const t = await setup()
  try {
    await assert.rejects(t.reader.getBlob(t.mainKey, t.h, { timeoutMs: 2_000 }), /not one of this relay's vaults/)
    assert.equal(t.main.stats.requests, 0)
  } finally { await t.stop() }
})

test("a new key on every start", async () => {
  const a = await throwawayIdentity(), b = await throwawayIdentity()
  assert.notEqual(toHex(a.publicKey), toHex(b.publicKey))
})
