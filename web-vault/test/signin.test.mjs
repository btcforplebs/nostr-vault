// Sign-in and sign-out boundaries from Tron's review: the bunker's auth_url, the signer's pubkey, and what
// sign-out leaves behind on this browser.
import test from "node:test"
import assert from "node:assert/strict"
import { safeAuthUrl } from "../src/signer/nip46.js"
import { checkedPubkey, saveSession, loadSession } from "../src/session.js"
import { forgetThisBrowser, storeNames, onSignedOutElsewhere } from "../src/haven/vault.js"
import { checkSigned } from "../src/net/sync.js"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"

test("only http and https auth URLs are opened", () => {
  assert.equal(safeAuthUrl("https://bunker.example/approve?x=1"), "https://bunker.example/approve?x=1")
  assert.equal(safeAuthUrl("http://localhost:3000/auth"), "http://localhost:3000/auth")
  for (const bad of ["javascript:alert(1)", " JavaScript:alert(1)", "data:text/html,<script>1</script>", "file:///etc/passwd", "nostr:npub1x", "", "not a url", null])
    assert.equal(safeAuthUrl(bad), null, String(bad))
})

test("a signer's pubkey must be 64 lowercase hex characters", () => {
  const pk = "a".repeat(64)
  assert.equal(checkedPubkey(pk), pk)
  for (const bad of ["A".repeat(64), "a".repeat(63), "npub1" + "q".repeat(58), "", undefined, 42, { pubkey: pk }])
    assert.throws(() => checkedPubkey(bad), /isn't a public key/, String(bad))
})

function memStorage() {
  const m = new Map()
  return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
// indexedDB.deleteDatabase as sign-out sees it: success, or (for names in `stuck`) neither success nor error.
function fakeIdb(stuck = [], listed) {
  const deleted = []
  return {
    deleted,
    ...(listed ? { databases: async () => listed.map(name => ({ name, version: 1 })) } : {}),
    deleteDatabase(name) {
      const req = {}
      if (!stuck.includes(name)) setTimeout(() => { deleted.push(name); req.onsuccess?.() })
      return req
    },
  }
}

test("sign-out stops Haven and deletes the session, keys, paired vaults, log and every route store", async () => {
  const pk = "b".repeat(64)
  const storage = memStorage()
  saveSession({ method: "nip07", pubkey: pk }, storage)
  for (const k of ["nv-device-sk", "fips-relay-key", "fips-owners", "nv-log"]) storage.setItem(k, "x")
  storage.setItem("unrelated", "keep")
  let stopped = false
  const vault = { haven: { stop: async () => { stopped = true } } }
  const idb = fakeIdb()
  const { failed } = await forgetThisBrowser({ vault, pubkey: pk, storage, idb })
  assert.ok(stopped)
  assert.deepEqual(failed, [])
  assert.equal(loadSession(storage), null)
  assert.deepEqual([...storage.m.keys()], ["unrelated"])
  for (const r of ["private", "chat", "outbox", "inbox", "blossom", "feed"]) {
    assert.ok(idb.deleted.includes(`haven:${pk}:${r}`), `haven:${pk}:${r}`)
    assert.ok(idb.deleted.includes(`haven:${r}`), `legacy haven:${r}`)
  }
})

test("a store that won't delete is reported, and sign-out still finishes", async () => {
  const pk = "c".repeat(64)
  const idb = fakeIdb([`haven:${pk}:feed`])
  const { failed } = await forgetThisBrowser({ vault: null, pubkey: pk, storage: memStorage(), idb, waitMs: 20 })
  assert.deepEqual(failed, [`haven:${pk}:feed`])
})

test("a store the browser lists is deleted even if the route list doesn't know it; other databases are left", async () => {
  const pk = "d".repeat(64)
  const idb = fakeIdb([], [`haven:${pk}:newroute`, `haven:${pk}:feed`, "someone-else"])
  const { failed } = await forgetThisBrowser({ vault: null, pubkey: pk, storage: memStorage(), idb })
  assert.deepEqual(failed, [])
  assert.ok(idb.deleted.includes(`haven:${pk}:newroute`))
  assert.ok(!idb.deleted.includes("someone-else"))
  // Without indexedDB.databases() (older Firefox) the known route list is still used.
  assert.equal((await storeNames(pk, fakeIdb())).length, 12)
})

test("a key another tab writes back while the stores are deleting is dropped again", async () => {
  const pk = "e".repeat(64)
  const storage = memStorage()
  const idb = fakeIdb()
  const del = idb.deleteDatabase
  idb.deleteDatabase = name => { storage.setItem("nv-device-sk", "recreated"); return del(name) }
  await forgetThisBrowser({ vault: null, pubkey: pk, storage, idb })
  assert.equal(storage.getItem("nv-device-sk"), null)
})

test("another tab signing out, or in as someone else, stops this one; its own account changing nothing doesn't", () => {
  const pk = "f".repeat(64)
  const target = new EventTarget()
  const fire = (key, newValue) => target.dispatchEvent(Object.assign(new Event("storage"), { key, newValue }))
  let gone = 0
  const off = onSignedOutElsewhere(pk, () => gone++, target)
  fire("nv-log", "[]")
  fire("nv-session", JSON.stringify({ method: "nip07", pubkey: pk }))
  assert.equal(gone, 0)
  fire("nv-session", null)
  assert.equal(gone, 1)
  fire("nv-session", null) // once is enough
  assert.equal(gone, 1)
  off()
  let other = 0
  onSignedOutElsewhere(pk, () => other++, target)
  fire("nv-session", JSON.stringify({ method: "nip07", pubkey: "0".repeat(64) }))
  assert.equal(other, 1)
  let cleared = 0
  onSignedOutElsewhere(pk, () => cleared++, target)
  fire(null, null) // localStorage.clear()
  assert.equal(cleared, 1)
})

test("a note is only published if the signed-in account signed exactly what was asked", () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const template = { kind: 1, created_at: 1700000000, tags: [], content: "hi" }
  const good = finalizeEvent({ ...template }, sk)
  assert.deepEqual(checkSigned(good, template, pk), { ...good })
  // The extension switched to another account mid-session.
  const other = finalizeEvent({ ...template }, generateSecretKey())
  assert.throws(() => checkSigned(other, template, pk), /different account/)
  assert.throws(() => checkSigned(undefined, template, pk), /different account/)
  // The signer changed what it signed.
  assert.throws(() => checkSigned(finalizeEvent({ ...template, content: "bye" }, sk), template, pk), /changed the note/)
  assert.throws(() => checkSigned(finalizeEvent({ ...template, tags: [["p", pk]] }, sk), template, pk), /changed the note/)
  // Claims the right pubkey but the signature doesn't hold.
  // The spread also copies nostr-tools' cached "verified" flag, which checkSigned must not trust.
  const forged = { ...other, pubkey: pk }
  assert.throws(() => checkSigned(forged, template, pk), /bad signature/)
  assert.throws(() => checkSigned({ ...good, sig: "0".repeat(128) }, template, pk), /bad signature/)
})
