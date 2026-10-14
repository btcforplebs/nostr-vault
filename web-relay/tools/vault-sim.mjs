// Stand-in vault for testing the browser relay without a phone: a fips-ts node with the given key, over the public seed, opens TCP/FIPS to the browser relay
// and sends a NIP-01 REQ. Usage (from web-relay/): node tools/vault-sim.mjs <secretHex> <relayNpub> [noteId]
import { FipsNode, identityFromSecretKey, decodeNpub, toHex } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { FipsTcpEndpoint } from "@fips/tcp"
const [sk, relayNpub, noteId] = process.argv.slice(2)
const identity = await identityFromSecretKey(Uint8Array.from(Buffer.from(sk, "hex")))
const node = new FipsNode({ identity, transports: [new WebSocketTransport({ seedUrls: ["wss://fips1.iris.to/fips"] })] })
const t0 = Date.now(), T = () => ((Date.now() - t0) / 1000).toFixed(1) + "s"
node.on("peer", p => console.log(T(), "peer", p.state, p.remoteAddr?.transport))
node.on("session", s => console.log(T(), "session", s.state))
await node.start()
await new Promise(r => setTimeout(r, 3000))
const relayKey = "02" + toHex(decodeNpub(relayNpub))
const tcp = new FipsTcpEndpoint(node, 7447)
let id
try { id = await tcp.connect(relayKey) } catch (e) { console.log(T(), "connect threw", String(e)); }
const filter = noteId ? { ids: [noteId] } : { kinds: [1], limit: 3 }
let sent = false, buf = "", result = "TIMEOUT"
const deadline = Date.now() + 45000
while (Date.now() < deadline && id !== undefined) {
  await tcp.poll()
  const st = await tcp.state(id)
  if (st === undefined) { result = "CONNECTION GONE (no accept)"; break }
  if (st === "established" && !sent) { await tcp.write(id, Buffer.from(JSON.stringify(["REQ", "g3", filter]) + "\n")); sent = true; console.log(T(), "established, REQ sent") }
  for (let b; (b = await tcp.read(id, 65536)).length; ) buf += Buffer.from(b).toString()
  const lines = buf.split("\n").filter(Boolean).map(l => JSON.parse(l))
  if (lines.some(l => l[0] === "EOSE")) { result = `EOSE after ${lines.filter(l => l[0] === "EVENT").length} EVENT(s): ` + lines.filter(l => l[0] === "EVENT").map(l => l[2].id.slice(0, 12) + " " + JSON.stringify(l[2].content.slice(0, 40))).join(" | "); break }
  await new Promise(r => setTimeout(r, 50))
}
console.log(T(), "RESULT", sent ? "" : "(never established)", result)
await node.stop(); process.exit(0)
