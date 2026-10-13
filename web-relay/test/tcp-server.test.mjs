// TCP/FIPS NIP-01 server: real @fips/tcp on both ends, an in-memory datagram fabric (with loss), and a stub
// of Haven's JS entry point (test/support/haven-stub.js) behind it. Run: node --test test/
import { test } from "node:test"
import assert from "node:assert/strict"
import { FipsTcpEndpoint } from "@fips/tcp"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { TcpFipsRelayServer, RELAY_SERVICE_PORT, MAX_LINE_IN, MAX_CONNECTIONS_PER_PEER } from "../src/fips/tcp-server.js"
import { parseOwners } from "../src/fips/owners.js"
import { wrap } from "../src/haven/haven.js"
import { HavenClient } from "../src/haven/client.js"
import { havenStub } from "./support/haven-stub.js"
import { fabric } from "./support/fabric.js"

const P = RELAY_SERVICE_PORT
const compressed = sk => "02" + getPublicKey(sk) // even-parity form, like FIPS reports

async function setup({ loss = 0, clientIsOwner = true } = {}) {
  const net = fabric(loss)
  const relaySk = generateSecretKey(), vaultSk = generateSecretKey(), strangerSk = generateSecretKey()
  const relayKey = compressed(relaySk)
  const clientSk = clientIsOwner ? vaultSk : strangerSk
  // FipsTcpEndpoint stamps inbound segments with Date.now(), so the simulated clock must be Date.now itself.
  let now = 1_760_000_000_000
  Date.now = () => now
  const stub = havenStub()
  const haven = wrap(stub)
  await haven.start({ ownerNpub: npubEncode(getPublicKey(vaultSk)) })
  // The page's own stream: how events get into Haven other than over FIPS.
  const page = new HavenClient(haven.conn("page", { mode: "nip01", route: "/" }))
  const owners = parseOwners(getPublicKey(vaultSk))
  const server = new TcpFipsRelayServer(net.endpoint(relayKey), haven, () => owners, { clock: () => now })
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
  return { server, client, id, stub, page, send, until, lines, pump, vaultSk, relayKey, step, state: () => client.state(id) }
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
  assert.deepEqual(await t.page.event(later), { ok: true, message: "" })
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
  for (const e of evs) assert.ok((await t.page.event(e)).ok)
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

test("a closed connection does not wedge the server: the next one is served", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  await t.send(["REQ", "a", { kinds: [1] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EOSE" && l[1] === "a")))
  // Graceful close from the vault: CLOSE, FIN, the server closes back, the stack forgets the connection.
  await t.send(["CLOSE", "a"])
  await t.client.close(t.id, Date.now())
  assert.ok(await t.until(() => t.server.stats.open === 0, 6000), "server let go of the closed connection")
  // A second connection from the same vault gets its REQ answered.
  const id2 = await t.client.connect(t.relayKey, Date.now())
  let buf = ""
  const got = async () => { for (let b; (b = await t.client.read(id2, 65536, Date.now())).length; ) buf += Buffer.from(b).toString(); return buf.includes('"EOSE","b"') }
  let sent = false
  for (let k = 0; k < 3000 && !(await got()); k++) {
    await t.step()
    if (!sent && (await t.client.state(id2)) === "established") { await t.client.write(id2, Buffer.from(JSON.stringify(["REQ", "b", { kinds: [1] }]) + "\n"), Date.now()); sent = true }
  }
  assert.ok(buf.includes('"EOSE","b"'), "second connection got EOSE")
})

test("each TCP connection is its own Haven stream, nip01 on the outbox route", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  const fips = t.stub.conns.filter(c => c.id !== "page")
  assert.equal(fips.length, 1)
  assert.match(fips[0].id, /^fips-/)
  // peer is the vault's x-only key, so Haven's rate limiters share one bucket across its reconnects.
  assert.deepEqual(fips[0].opts, { mode: "nip01", route: "/", peer: getPublicKey(t.vaultSk) })
  assert.equal(fips[0].opts.owner, undefined, "a FIPS stream never gets the owner's limiter bypass")
})

test("oversized line: the server aborts before Haven sees more than MAX_LINE_IN bytes", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  const fips = t.stub.conns.find(c => c.id !== "page").conn
  let fed = 0
  const write = fips.write
  fips.write = b => { fed += b.length; write(b) }
  const huge = Buffer.alloc(MAX_LINE_IN + 128 * 1024, 0x61) // no newline
  let off = 0
  while (off < huge.length && (await t.state()) === "established") { try { off += await t.client.write(t.id, huge.subarray(off), Date.now()) } catch { break } await t.pump() }
  assert.ok(await t.until(() => t.server.conns.size === 0))
  assert.ok(fed <= MAX_LINE_IN, `Haven was fed ${fed} bytes of one line`)
})

test("one vault gets at most MAX_CONNECTIONS_PER_PEER connections", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  const extra = []
  for (let i = 1; i < MAX_CONNECTIONS_PER_PEER + 2; i++) extra.push(await t.client.connect(t.relayKey, Date.now()))
  const t0 = Date.now()
  await t.until(() => false, 400)
  assert.equal(t.server.stats.accepted, MAX_CONNECTIONS_PER_PEER)
  assert.ok(t.server.stats.refusedSyns > 0, "the extra SYNs were refused at the gate, not thrown")
  assert.equal(t.server.stats.lastDropError, "connection limit reached")
  // Refused with an RST: the vault's connect fails within the run, not after minutes of SYN retries.
  const gone = []
  for (const id of extra) if ((await t.client.state(id)) === undefined) gone.push(id)
  assert.equal(gone.length, 2, "both over-cap connects were reset")
  assert.ok(Date.now() - t0 < 10_000, `reset took ${Date.now() - t0} ms of simulated clock`)
  // The connections it does hold are still served.
  await t.send(["REQ", "after", { kinds: [1] }])
  assert.ok(await t.until(() => t.lines.some(l => l[0] === "EOSE" && l[1] === "after")))
})

test("Haven hanging up closes the TCP connection", async () => {
  const t = await setup()
  assert.ok(await t.until(() => t.server.stats.accepted === 1))
  t.stub.conns.find(c => c.id !== "page").conn.close()
  assert.ok(await t.until(() => t.server.stats.open === 0 && t.server.conns.size === 0, 6000))
})
