// Live check of the page's photo read over the public seed, with throwaway keys (from web-relay/):
//   node tools/blob-vault-sim.mjs serve [file]                     stand-in vault: serves one blob on mesh port 80
//   node tools/blob-vault-sim.mjs get <vaultNpub> <sha256> [file]  the page's reader (MeshBlobClient), like the page
//   node tools/blob-vault-sim.mjs both [file]                      both, as two nodes on the seed, in one process
// The vault serves HTTP over real TCP in the IPv6 shim (tools/lib/mesh-http-vault.js), as a native vault does.
// The reader is a non-forwarding fips-ts node with the page's seed, opening the session the way the page does.
// Exit 0 only when the bytes read hash to the sha256 asked for (and equal [file] when given).
import { readFileSync } from "node:fs"
import { createHash, randomBytes } from "node:crypto"
import { FipsNode, generateIdentity, encodeNpub, decodeNpub, toHex } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { MeshBlobClient } from "../src/fips/blob-get.js"
import { meshHttpVault } from "./lib/mesh-http-vault.js"

// The page's seeds (src/fips/node.js PUBLIC_SEEDS). FIPS_SEED=<url> pins one. Both matter: a seed doesn't always
// route to a vault whose tree parent is the other seed.
const SEEDS = process.env.FIPS_SEED ? [process.env.FIPS_SEED] : ["wss://fips1.iris.to/fips", "wss://fips2.iris.to/fips"]
const t0 = Date.now(), T = () => ((Date.now() - t0) / 1000).toFixed(1).padStart(5) + "s"
const sha = b => createHash("sha256").update(b).digest("hex")

async function startNode(label) {
  const identity = await generateIdentity()
  const node = new FipsNode({ identity, transports: [new WebSocketTransport({ seedUrls: SEEDS })], forwarding: false })
  node.on("peer", p => console.log(T(), label, "peer", p.state, p.remoteAddr?.transport, p.remoteAddr?.addr ?? ""))
  node.on("session", s => console.log(T(), label, "session", s.state))
  await node.start()
  console.log(T(), label, "npub", encodeNpub(identity.xOnlyPubkey))
  return { node, identity }
}

async function serve(file) {
  const bytes = file ? new Uint8Array(readFileSync(file)) : new Uint8Array(randomBytes(200_000))
  const h = sha(bytes)
  const v = await startNode("vault")
  const vault = meshHttpVault(v.node, v.identity.publicKey, new Map([[h, { bytes, type: file?.endsWith(".png") ? "image/png" : "image/jpeg" }]]), { log: m => console.log(T(), "vault", m) })
  const timer = setInterval(() => vault.tick().catch(e => console.log(T(), "vault tick", String(e))), 20)
  console.log(T(), "vault serving", bytes.length, "bytes, sha256", h)
  return { ...v, vault, h, bytes, stop: async () => { clearInterval(timer); await vault.stop(); await v.node.stop() } }
}

async function get(vaultNpub, h, expect) {
  const r = await startNode("page ")
  await new Promise(res => setTimeout(res, 3000))
  const vaultKey = toHex(decodeNpub(vaultNpub))
  const client = new MeshBlobClient(r.node, r.identity.publicKey, { allow: k => String(k).slice(-64) === vaultKey })
  // As the page's dialOwners does: an empty datagram opens the session through the seed.
  await r.node.sendDatagram({ dst: "02" + vaultKey, srcPort: 7447, dstPort: 7447, payload: new Uint8Array(0) }).catch(e => console.log(T(), "dial", String(e)))
  let ok = false
  try {
    const t1 = Date.now()
    const got = await client.get(vaultKey, h, { timeoutMs: 90_000, onProgress: n => n % 50_000 < 5_000 && console.log(T(), "page  read", n) })
    const match = sha(got.bytes) === h && (!expect || Buffer.compare(Buffer.from(got.bytes), Buffer.from(expect)) === 0)
    console.log(T(), "RESULT", match ? "BYTES MATCH" : "MISMATCH", got.bytes.length, "bytes", got.type, "sha256", sha(got.bytes), `${Date.now() - t1}ms`)
    ok = match
  } catch (e) {
    console.log(T(), "RESULT FAILED", String(e?.message ?? e), JSON.stringify(client.stats))
  }
  await client.stop()
  await r.node.stop()
  return ok
}

const [mode, ...rest] = process.argv.slice(2)
let ok = false
if (mode === "serve") {
  await serve(rest[0])
  await new Promise(() => {})
} else if (mode === "get") {
  ok = await get(rest[0], rest[1], rest[2] && readFileSync(rest[2]))
} else if (mode === "both") {
  const v = await serve(rest[0])
  ok = await get(encodeNpub(v.identity.xOnlyPubkey), v.h, v.bytes)
  console.log(T(), "vault stats", JSON.stringify(v.vault.stats))
  await v.stop()
} else {
  console.log("usage: node tools/blob-vault-sim.mjs serve [file] | get <vaultNpub> <sha256> [file] | both [file]")
}
process.exit(ok ? 0 : 1)
