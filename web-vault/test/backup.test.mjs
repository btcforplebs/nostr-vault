// Notes backup (src/net/backup.js): the zip format the iPhone uses, and export/restore through the real haven.wasm.
// The Haven tests are skipped until web-relay/tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { wrap } from "../../web-relay/src/haven/haven.js"
import { zip, unzip, crc32, exportNotes, importNotes, readAll, DATABASES } from "../src/net/backup.js"

const enc = s => new TextEncoder().encode(s)
const dec = b => new TextDecoder().decode(b)

test("crc32 matches the standard check value", () => {
  assert.equal(crc32(enc("123456789")), 0xcbf43926)
})

test("zip round-trips, deflated and stored", async () => {
  const files = [{ name: "outbox.jsonl", data: enc('{"a":1}\n'.repeat(500)) }, { name: "empty.jsonl", data: new Uint8Array() }]
  for (const deflate of [true, false]) {
    const z = await zip(files, { deflate })
    const got = await unzip(z)
    assert.deepEqual(got.map(e => e.name), ["outbox.jsonl", "empty.jsonl"])
    assert.equal(dec(await got[0].read()), '{"a":1}\n'.repeat(500))
    assert.equal((await got[1].read()).length, 0)
    if (deflate) assert.ok(z.length < 1000, "deflated")
  }
})

test("a damaged or foreign file is refused with a message", async () => {
  await assert.rejects(unzip(enc("not a zip at all, just some text that is long enough")), /isn't a backup/)
  const z = await zip([{ name: "outbox.jsonl", data: enc("hello\n") }], { deflate: false })
  const at = z.indexOf(enc("hello")[0], 30)
  z[at] ^= 0xff
  await assert.rejects((await unzip(z))[0].read(), /damaged/)
})

// Data descriptors and sizes only in the central directory, as Go's archive/zip writes them (haven-go exportToZip).
test("reads an entry whose local header has no sizes (Go's streaming writer)", async () => {
  const z = await zip([{ name: "feed.jsonl", data: enc("x\n") }], { deflate: false })
  const v = new DataView(z.buffer)
  v.setUint16(6, 0x0808, true); v.setUint32(18, 0, true); v.setUint32(22, 0, true) // flag 8, zero sizes in the local header
  assert.equal(dec(await (await unzip(z))[0].read()), "x\n")
})

test("readAll pages back by created_at and gets past a full page of one second", async () => {
  const evs = Array.from({ length: 23 }, (_, i) => ({ id: String(i).padStart(64, "0"), created_at: i < 12 ? 100 : 200 + i }))
  const client = { query: async f => evs.filter(e => (f.until === undefined || e.created_at <= f.until) && (f.since === undefined || e.created_at >= f.since)).sort((a, b) => b.created_at - a.created_at).slice(0, f.limit) }
  const got = await readAll(client, { kinds: [1] }, 5)
  assert.equal(got.length, 23)
  assert.equal(new Set(got.map(e => e.id)).size, 23)
})

// ---- the real Haven ----
const WASM = new URL("../../web-relay/public/haven.wasm", import.meta.url)
const SHIM = new URL("../../web-relay/src/haven/wasm_exec.js", import.meta.url)
const skip = !(existsSync(WASM) && existsSync(SHIM)) && "web-relay/public/haven.wasm not built"
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

test("real Haven: export reads every database, restore puts it back and refuses what doesn't belong", { skip }, async () => {
  const owner = generateSecretKey(), device = generateSecretKey(), friend = generateSecretKey(), stranger = generateSecretKey()
  const me = getPublicKey(owner)
  const h = await boot()
  const start = prefix => h.start({ ownerNpub: npubEncode(me), whitelist: [npubEncode(getPublicKey(device))], env: { RELAY_URL: "vault.local" }, storePrefix: prefix })
  await start("backup-a")
  const vault = { haven: h }
  const now = Math.floor(Date.now() / 1000)
  const ev = (sk, kind, tags = [], content = "", at = now) => finalizeEvent({ kind, created_at: at, tags, content }, sk)
  const seed = {
    outbox: [ev(owner, 1, [], "my note"), ev(owner, 0, [], "{}"), ...Array.from({ length: 30 }, (_, i) => ev(owner, 1, [], `old ${i}`, now - 1000 - i))],
    private: [ev(owner, 30078, [["d", "draft"]], "secret draft")],
    chat: [ev(stranger, 1059, [["p", me]], "wrapped")],
    inbox: [ev(friend, 1, [["p", me]], "hi you")],
    feed: [ev(friend, 1, [], "friend note"), ev(friend, 30023, [["d", "a"]], "article")],
  }
  // Seed through the same AUTHed owner streams the backup uses: import into an empty store.
  const seedZip = await zip(Object.entries(seed).map(([n, evs]) => ({ name: `${n}.jsonl`, data: enc(evs.map(e => JSON.stringify(e)).join("\n") + "\n") })))
  const seeded = await importNotes({ vault, pubkey: me, bytes: seedZip, sk: device })
  for (const [n, evs] of Object.entries(seed)) assert.deepEqual(seeded.counts[n], { stored: evs.length, refused: 0, bad: 0 }, n + JSON.stringify(seeded.counts[n]))

  const out = await exportNotes({ vault, pubkey: me, sk: device })
  for (const [n, evs] of Object.entries(seed)) assert.equal(out.counts[n], evs.length, `export ${n}`)
  const bytes = new Uint8Array(await out.blob.arrayBuffer())
  const entries = await unzip(bytes)
  assert.deepEqual(entries.map(e => e.name).sort(), Object.keys(DATABASES).map(n => `${n}.jsonl`).sort())

  // Restore into a fresh, empty set of stores for the same account.
  await h.stop()
  await start("backup-b")
  const back = await importNotes({ vault, pubkey: me, bytes, sk: device })
  for (const [n, evs] of Object.entries(seed)) assert.deepEqual(back.counts[n], { stored: evs.length, refused: 0, bad: 0 }, `restore ${n}`)
  const again = await exportNotes({ vault, pubkey: me, sk: device })
  assert.deepEqual(again.counts, out.counts, "what was restored reads back the same")

  // Restoring twice is harmless: duplicates are already there.
  const twice = await importNotes({ vault, pubkey: me, bytes, sk: device })
  assert.equal(twice.counts.outbox.stored, seed.outbox.length)

  // A crafted backup: a stranger's note in the outbox, a forged signature, a line that isn't JSON, an unknown file.
  const forged = { ...ev(owner, 1, [], "forged") , content: "changed after signing" }
  const bad = await zip([
    { name: "outbox.jsonl", data: enc([ev(stranger, 1, [], "not yours"), forged].map(e => JSON.stringify(e)).join("\n") + "\nnot json\n") },
    { name: "blossom.jsonl", data: enc("") },
  ])
  const r = await importNotes({ vault, pubkey: me, bytes: bad, sk: device })
  assert.deepEqual(r.counts.outbox, { stored: 0, refused: 2, bad: 1, why: "invalid: id is computed incorrectly" }) // the stranger's note never reached Haven
  assert.deepEqual(r.skipped, ["blossom.jsonl"])
  const after2 = await exportNotes({ vault, pubkey: me, sk: device })
  assert.equal(after2.counts.outbox, seed.outbox.length, "nothing from the crafted backup got in")
})
