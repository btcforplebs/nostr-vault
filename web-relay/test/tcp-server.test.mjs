// TCP/FIPS NIP-01 server: real @fips/tcp on both ends, an in-memory datagram fabric (with loss),
// the relay's real signature check behind an in-memory store. Run: node --test test/
import { test } from "node:test"
import assert from "node:assert/strict"
import { FipsTcpEndpoint } from "@fips/tcp"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { matchFilters } from "nostr-tools/filter"
import { TcpFipsRelayServer, RELAY_SERVICE_PORT } from "../src/fips/tcp-server.js"
import { parseOwners } from "../src/fips/owners.js"
import { rejectReason } from "../src/worker-relay/verify.ts"

const P = RELAY_SERVICE_PORT
const compressed = sk => "02" + getPublicKey(sk) // even-parity form, like FIPS reports

// Datagram fabric: queue per step, optional loss with a seeded PRNG.
function fabric(loss = 0, seed = 7) {
  let s = seed
  const rnd = () => ((s = (s * 1103515245 + 12345) >>> 0) / 2 ** 32)
  const nodes = new Map(), queue = []
  const endpoint = key => {
    const handlers = new Map()
    nodes.set(key, handlers)
    return {
      registerService: (port, h) => (handlers.set(port, h), () => handlers.delete(port)),
      sendDatagram: async ({ dst, srcPort, dstPort, payload }) => { if (rnd() >= loss) queue.push({ src: key, dst, srcPort: srcPort ?? dstPort, dstPort, payload: payload.slice() }) },
    }
  }
  const deliver = async () => {
    for (const d of queue.splice(0)) await nodes.get(d.dst)?.get(d.dstPort)?.({ src: d.src, srcPort: d.srcPort, dstPort: d.dstPort, payload: d.payload })
  }
  return { endpoint, deliver }
}

function memStore() {
  const evs = new Map()
  return {
    evs,
    event: async ev => { const r = rejectReason(ev); if (r) return { ok: false, message: r }; evs.set(ev.id, ev); return { ok: true } },
    query: async fs => [...evs.values()].filter(e => matchFilters(fs, e)),
    count: async fs => [...evs.values()].filter(e => matchFilters(fs, e)).length,
  }
}

async function setup({ loss = 0, clientIsOwner = true } = {}) {
  const net = fabric(loss)
  const relaySk = generateSecretKey(), vaultSk = generateSecretKey(), strangerSk = generateSecretKey()
  const relayKey = compressed(relaySk)
  const clientSk = clientIsOwner ? vaultSk : strangerSk
  // FipsTcpEndpoint stamps inbound segments with Date.now(), so the simulated clock must be Date.now itself.
  let now = 1_760_000_000_000
  Date.now = () => now
  const store = memStore()
  const owners = parseOwners(getPublicKey(vaultSk))
  const server = new TcpFipsRelayServer(net.endpoint(relayKey), store, () => owners, { clock: () => now })
  const client = new FipsTcpEndpoint(net.endpoint(compressed(clientSk)), P)
  const id = await client.connect(relayKey, now)
  const step = async () => { now += 10; await client.poll(now); await server.tick(); await net.deliver() }
  const lines = []
  let buf = ""
  const pump = async () => {
    await step()
    if ((await client.state(id)) === undefined) return
    for (let b; (b = await client.read(id, 65536, now)).length; ) buf += Buffer.from(b).toString("utf8")
    let i
    while ((i = buf.indexOf("\n")) >= 0) { lines.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1) }
  }
  const send = async msg => { const b = Buffer.from(JSON.stringify(msg) + "\n"); let off = 0; while (off < b.length) { off += await client.write(id, b.subarray(off), now); await pump() } }
  const until = async (pred, max = 3000) => { for (let k = 0; k < max; k++) { if (pred()) return true; await pump() } return pred() }
  return { server, client, id, store, send, until, lines, pump, vaultSk, state: () => client.state(id) }
}

const note = (sk, content) => finalizeEvent({ kind: 1, created_at: 1760000000, tags: [], content }, sk)

test("owner: EVENT, forged EVENT, REQ+EOSE, live EVENT, COUNT", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1), "owner connection accepted")
  const ev = note(t.vaultSk, "hello over TCP/FIPS")
  await t.send(["EVENT", ev])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "OK" && l[1] === ev.id)))
  assert.deepEqual(t.lines.find(l => l[0] === "OK"), ["OK", ev.id, true, ""])

  const forged = { ...ev, content: "tampered" }
  await t.send(["EVENT", forged])
  assert.ok(await t.until(() => t.lines.filter(l => l[0] === "OK").length === 2))
  const ok2 = t.lines.filter(l => l[0] === "OK")[1]
  assert.equal(ok2[2], false)
  assert.match(ok2[3], /^invalid:/)

  await t.send(["REQ", "s1", { ids: [ev.id] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EOSE" && l[1] === "s1")))
  assert.deepEqual(t.lines.filter(l => l[0] === "EVENT" && l[1] === "s1").map(l => l[2].id), [ev.id])

  await t.send(["REQ", "live", { kinds: [1], authors: [getPublicKey(t.vaultSk)] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EOSE" && l[1] === "live")))
  const later = note(t.vaultSk, "inserted by the page")
  await t.store.event(later)
  t.server.notify(later)
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EVENT" && l[1] === "live" && l[2].id === later.id)), "live event forwarded")

  await t.send(["COUNT", "c", { kinds: [1] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "COUNT")))
  assert.deepEqual(t.lines.find(l => l[0] === "COUNT"), ["COUNT", "c", { count: 2 }])
})

test("stranger: SYN is dropped, never accepted, no reply", async () => {
  const t = await setup({ clientIsOwner: false })
  await t.until(() => false, 400)
  assert.equal(t.server.stats.accepted, 0)
  assert.ok(t.server.stats.rejectedDatagrams > 0, "stranger datagrams reached the gate")
  assert.notEqual(await t.state(), "established")
})

for (const loss of [0, 0.15]) test(`owner over a lossy link (${loss * 100}% loss): REQ still answered`, async () => {
  const t = await setup({ loss })
  const evs = Array.from({ length: 40 }, (_, i) => note(t.vaultSk, "n" + i + " " + "x".repeat(900)))
  for (const e of evs) await t.store.event(e)
  assert.ok(await t.until(() => t.server.stats.accepted === 1, 6000))
  await t.send(["REQ", "all", { kinds: [1] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EOSE"), 20000), "EOSE arrived")
  assert.equal(t.lines.filter(l => l[0] === "EVENT").length, 40)
})

test("oversized line: NOTICE then the stream is aborted", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  const huge = Buffer.alloc(600 * 1024, 0x61) // no newline
  let off = 0
  while (off < huge.length && (await t.state()) === "established") { try { off += await t.client.write(t.id, huge.subarray(off), Date.now()) } catch { break } await t.pump() }
  assert.ok(await t.until(() => t.server.stats.open === 0 && t.server.conns.size === 0))
})
