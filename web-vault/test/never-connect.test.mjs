// The Never Connect list (kind 10006) as the iPhone's RelayBlocklist: the pool refuses those relays (a bunker's own
// relay excepted), closes them if open, and the account carries the list from Haven.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { pool } from "../src/net/pool.js"
import { blocklist, isPublicRelay, neverConnectUrls, readKept, keep } from "../src/net/never-connect.js"
import { readAccount } from "../src/net/sync.js"

after(() => pool.destroy())

test("a relay with no path blocks its whole host and port; a path blocks only that path", () => {
  const b = blocklist(["wss://Relay.Example/", "wss://other.example/inbox", "wss://port.example:8443"])
  assert.equal(b("wss://relay.example"), true)
  assert.equal(b("wss://relay.example/inbox"), true, "no path: every path on the host")
  assert.equal(b("wss://relay.example:8443"), false, "another port")
  assert.equal(b("wss://other.example/inbox/"), true)
  assert.equal(b("wss://other.example"), false, "a path blocks only itself")
  assert.equal(b("wss://port.example:8443/x"), true)
  assert.equal(b("wss://port.example"), false)
  assert.equal(b("wss://relay.primal.net"), false)
  assert.equal(b("not a url"), false)
})

test("relays that aren't public are never blocked: the user's own vault lives there", () => {
  for (const u of ["ws://localhost:3355", "wss://localhost", "wss://127.0.0.1", "wss://192.168.1.4", "wss://10.0.0.2", "wss://172.20.0.1", "wss://abc.onion", "wss://mac.local", "ws://relay.example"]) {
    assert.equal(isPublicRelay(u), false, u)
    assert.equal(blocklist([u])(u), false, u)
  }
  assert.equal(isPublicRelay("wss://172.32.0.1"), true)
})

test("the pool refuses a Never Connect relay, closes it if open, and a bunker's relay still connects", async t => {
  const base = Object.getPrototypeOf(Object.getPrototypeOf(pool)) // SimplePool's ensureRelay: no real connection here
  t.mock.method(base, "ensureRelay", async url => ({ url }))
  t.after(() => { pool.setNeverConnect([]); pool.signerRelays.clear() })
  let closed = 0
  pool.relays.set("wss://blocked.example/", { close: () => closed++ })
  pool.setNeverConnect(["wss://blocked.example", "wss://bunker.example"])
  assert.equal(closed, 1)
  assert.equal(pool.relays.has("wss://blocked.example/"), false, "open socket dropped")
  await assert.rejects(pool.ensureRelay("wss://blocked.example/x"), /Never Connect/)
  pool.keepForSigner(["wss://bunker.example"])
  assert.deepEqual(await pool.ensureRelay("wss://bunker.example"), { url: "wss://bunker.example" })
  assert.deepEqual(await pool.ensureRelay("wss://fine.example"), { url: "wss://fine.example" })
  pool.setNeverConnect([])
  assert.deepEqual(await pool.ensureRelay("wss://blocked.example"), { url: "wss://blocked.example" }, "unblocked")
})

test("the account carries the newest 10006's relays, or null when Haven has none", async () => {
  const ev = (kind, created_at, tags) => ({ kind, created_at, tags, pubkey: "a".repeat(64), content: "" })
  const vault = evs => ({ outbox: { query: async f => evs.filter(e => f.kinds.includes(e.kind)) } })
  const lists = [ev(10006, 1, [["relay", "wss://old.example"]]), ev(10006, 2, [["relay", "wss://new.example"], ["relay", "https://x"], ["p", "b"]])]
  assert.deepEqual((await readAccount(vault(lists), "a".repeat(64))).neverConnect, ["wss://new.example"])
  assert.equal((await readAccount(vault([]), "a".repeat(64))).neverConnect, null)
  assert.deepEqual(neverConnectUrls(ev(10006, 3, [])), [], "an emptied list is a list: it unblocks everything")
})

test("the list is kept per account for the next visit's first sockets", () => {
  const m = new Map(), storage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: k => m.delete(k) }
  keep("me", ["wss://a.example"], storage)
  assert.deepEqual(readKept("me", storage), ["wss://a.example"])
  assert.deepEqual(readKept("other", storage), [])
  keep("me", [], storage)
  assert.deepEqual(readKept("me", storage), [])
})
