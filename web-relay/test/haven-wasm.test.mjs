// The real haven.wasm under node (Haven picks its memstore there), driven through the same client and
// TCP/FIPS server the page uses. Skipped until tools/build-haven-wasm.sh has been run.
import { test } from "node:test"
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
