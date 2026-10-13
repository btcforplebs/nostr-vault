// The real haven.wasm under node (Haven picks its memstore there), driven through the same client and
// TCP/FIPS server the page uses. Skipped until tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { wrap } from "../src/haven/haven.js"
import { HavenClient } from "../src/haven/client.js"

const WASM = new URL("../public/haven.wasm", import.meta.url)
const SHIM = new URL("../src/haven/wasm_exec.js", import.meta.url)
const built = existsSync(WASM) && existsSync(SHIM)
const note = (sk, content) => finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content }, sk)

let haven
// The Go runtime keeps node's event loop alive after havenStop; end the file's process once its tests are done.
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

test("real Haven: outbox takes the owner's note, refuses a stranger's, serves REQ", { skip: !built && "public/haven.wasm not built" }, async () => {
  const owner = generateSecretKey(), stranger = generateSecretKey()
  const h = await boot()
  const t0 = Date.now()
  await h.start({ ownerNpub: npubEncode(getPublicKey(owner)) })
  console.log(`havenStart ${Date.now() - t0} ms`)
  const c = new HavenClient(h.conn("page", { mode: "nip01", route: "/" }))
  const a = note(owner, "owner note")
  assert.equal((await c.event(a)).ok, true)
  const x = await c.event(note(stranger, "stranger note"))
  assert.equal(x.ok, false, "stranger's note must be refused on the outbox")
  console.log("stranger refused:", x.message)
  assert.equal((await c.event({ ...note(owner, "y"), sig: "00".repeat(64) })).ok, false, "bad signature refused")
  assert.deepEqual((await c.query({ ids: [a.id] })).map(e => e.id), [a.id])
  c.close()
  await h.stop()
})

test("real Haven over TCP/FIPS: owner REQ gets EVENT + EOSE, a stranger's SYN gets nothing", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { FipsTcpEndpoint } = await import("@fips/tcp")
  const { TcpFipsRelayServer, RELAY_SERVICE_PORT: P } = await import("../src/fips/tcp-server.js")
  const { parseOwners } = await import("../src/fips/owners.js")
  const { fabric } = await import("./support/fabric.js")
  const vault = generateSecretKey(), stranger = generateSecretKey(), relay = generateSecretKey()
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(vault)) })
  const page = new HavenClient(h.conn("page", { mode: "nip01", route: "/" }))
  const stored = note(vault, "the note the vault asks for")
  assert.equal((await page.event(stored)).ok, true)

  const net = fabric()
  const relayKey = "02" + getPublicKey(relay)
  const owners = parseOwners(getPublicKey(vault))
  const server = new TcpFipsRelayServer(net.endpoint(relayKey), h, () => owners)
  const run = async sk => {
    const tcp = new FipsTcpEndpoint(net.endpoint("02" + getPublicKey(sk)), P)
    const id = await tcp.connect(relayKey, Date.now())
    let buf = "", sent = false
    for (let k = 0; k < 400 && !buf.includes('"EOSE"'); k++) {
      await tcp.poll(Date.now()); await server.tick(); await net.deliver()
      const st = await tcp.state(id)
      if (st === undefined) break
      if (st === "established" && !sent) { await tcp.write(id, Buffer.from(JSON.stringify(["REQ", "e2e", { ids: [stored.id] }]) + "\n"), Date.now()); sent = true }
      for (let b; (b = await tcp.read(id, 65536, Date.now())).length; ) buf += Buffer.from(b).toString()
      await new Promise(r => setTimeout(r, 5))
    }
    return buf.split("\n").filter(Boolean).map(l => JSON.parse(l))
  }
  const owned = await run(vault)
  assert.deepEqual(owned.filter(l => l[0] === "EVENT").map(l => l[2].id), [stored.id])
  assert.ok(owned.some(l => l[0] === "EOSE" && l[1] === "e2e"))
  const strangers = await run(stranger)
  assert.deepEqual(strangers, [])
  assert.ok(server.stats.rejectedDatagrams > 0)
  assert.equal(server.stats.accepted, 1, "only the owner's connection reached Haven")
  await server.stop()
  page.close()
  await h.stop()
})
