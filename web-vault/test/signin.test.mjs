// Sign-in and sign-out boundaries from Tron's review: the bunker's auth_url, the signer's pubkey, and what
// sign-out leaves behind on this browser.
import test from "node:test"
import assert from "node:assert/strict"
import { safeAuthUrl } from "../src/signer/nip46.js"
import { checkedPubkey, saveSession, loadSession } from "../src/session.js"
import { forgetThisBrowser } from "../src/haven/vault.js"

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
function fakeIdb(stuck = []) {
  const deleted = []
  return {
    deleted,
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
