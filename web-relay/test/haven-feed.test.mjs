// The real haven.wasm under node: /feed, the cache the web vault reads its Following feed from.
// Skipped until tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { makeAuthEvent } from "nostr-tools/nip42"
import { wrap } from "../src/haven/haven.js"
import { HavenClient } from "../src/haven/client.js"

const WASM = new URL("../public/haven.wasm", import.meta.url)
const SHIM = new URL("../src/haven/wasm_exec.js", import.meta.url)
const built = existsSync(WASM) && existsSync(SHIM)
const skip = !built && "public/haven.wasm not built"
const RELAY = "wss://vault.invalid" // Haven's ServiceURL is https://RELAY_URL/route; khatru compares it as wss
const now = () => Math.floor(Date.now() / 1000)
const note = (sk, content, at = now()) => finalizeEvent({ kind: 1, created_at: at, tags: [], content }, sk)
const signAuth = sk => challenge => finalizeEvent(makeAuthEvent(RELAY + "/feed", challenge), sk)

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

test("real Haven /feed: owner stream caches past the event limiter, device key AUTHs to read", { skip }, async () => {
  const owner = generateSecretKey(), device = generateSecretKey(), stranger = generateSecretKey(), follow = generateSecretKey()
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(owner)), whitelist: [npubEncode(getPublicKey(device))], env: { RELAY_URL: "vault.invalid" } })

  // The page's own stream: 150 follow notes, past the outbox limiter's burst of 100.
  const page = new HavenClient(h.conn("page-feed", { mode: "nip01", route: "/feed", owner: true }), { auth: signAuth(device) })
  const t0 = now() - 1000
  let ok = 0
  for (let i = 0; i < 150; i++) ok += (await page.event(note(follow, `follow ${i}`, t0 + i))).ok
  assert.equal(ok, 150, "every note the page caches is stored")
  assert.equal((await page.event(finalizeEvent({ kind: 0, created_at: now(), tags: [], content: "{}" }, follow))).ok, false, "only feed kinds")

  const got = await page.query({ kinds: [1], authors: [getPublicKey(follow)], limit: 20 })
  assert.equal(got.length, 20)
  assert.equal(got[0].content, "follow 149", "newest first")

  // A stream that isn't the owner's still hits the limiter.
  const other = new HavenClient(h.conn("other-feed", { mode: "nip01", route: "/feed" }))
  let limited = false
  for (let i = 0; i < 120 && !limited; i++) limited = !(await other.event(note(follow, `x ${i}`))).ok
  assert.ok(limited, "non-owner stream is rate limited")

  // Reads need AUTH from a whitelisted key: a stranger's AUTH is accepted but the read is still refused.
  const nosy = new HavenClient(h.conn("nosy", { mode: "nip01", route: "/feed" }), { auth: signAuth(stranger) })
  await assert.rejects(nosy.query({ kinds: [1], authors: [getPublicKey(follow)] }), /whitelisted/)
  const anon = new HavenClient(h.conn("anon", { mode: "nip01", route: "/feed" }))
  await assert.rejects(anon.query({ kinds: [1], authors: [getPublicKey(follow)] }), /auth-required/)

  for (const c of [page, other, nosy, anon]) c.close()
  await h.stop()
})
