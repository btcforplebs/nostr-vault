// Box mode (src/box): the vault is the box's relay on the page's own origin, reached through sockets that speak what a
// HavenClient expects; AUTH is signed by the signed-in owner for that socket's URL; the box API carries NIP-98.
// Fake sockets and a mock box: nothing leaves this process. Throwaway keys.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { unpackEventFromToken, validateEvent } from "nostr-tools/nip98"
import { HavenClient } from "../../web-relay/src/haven/client.js"
import { boxRelayUrl, boxApiBase, BOX } from "../src/box/mode.js"
import { boxConn, boxHaven, startBoxVault } from "../src/box/box-vault.js"
import { boxApi } from "../src/box/api.js"
import { mockBox } from "../src/box/mock.js"
import { bytes, uptime, share, ago } from "../src/box/format.js"

const owner = generateSecretKey(), device = generateSecretKey()
const signer = { signEvent: async t => finalizeEvent(t, owner) }
const loc = { protocol: "http:", host: "box.lan:8080", origin: "http://box.lan:8080" }

/** A box relay route over a fake socket: wants AUTH from the owner for its own URL before it answers a REQ. */
function fakeRelay({ owner: ownerPk = getPublicKey(owner) } = {}) {
  const sockets = []
  class Socket {
    constructor(url) {
      this.url = url; this.sent = []; this.authed = false; sockets.push(this)
      setTimeout(() => { this.onopen?.(); this.reply(["AUTH", "chal-1"]) }, 0)
    }
    reply(m) { this.onmessage?.({ data: JSON.stringify(m) }) }
    send(text) {
      const m = JSON.parse(text); this.sent.push(m)
      if (m[0] === "AUTH") {
        const ev = m[1], relay = ev.tags.find(t => t[0] === "relay")?.[1], ch = ev.tags.find(t => t[0] === "challenge")?.[1]
        this.authed = verifyEvent(ev) && ev.pubkey === ownerPk && relay === this.url && ch === "chal-1"
        return this.reply(["OK", ev.id, this.authed, this.authed ? "" : "auth-required: not the owner"])
      }
      if (m[0] === "REQ") {
        if (!this.authed) return this.reply(["CLOSED", m[1], "auth-required: owner only"])
        this.reply(["EVENT", m[1], { id: "e1", kind: 1, content: `from ${this.url}` }])
        return this.reply(["EOSE", m[1]])
      }
    }
    close() { this.onclose?.() }
  }
  return { Socket, sockets }
}

test("built without NV_BOX the app isn't in box mode", () => assert.equal(BOX, false))

test("the box relay and API are the page's own origin", () => {
  assert.equal(boxRelayUrl("/", loc), "ws://box.lan:8080/")
  assert.equal(boxRelayUrl("/feed", loc), "ws://box.lan:8080/feed")
  assert.equal(boxRelayUrl("/inbox", { ...loc, protocol: "https:" }), "wss://box.lan:8080/inbox")
  assert.equal(boxApiBase(loc), "http://box.lan:8080/api/box")
})

test("a route read goes to the box; the device-key AUTH is signed again by the owner for that socket's URL", async () => {
  const { Socket, sockets } = fakeRelay()
  const auth = ch => finalizeEvent({ kind: 22242, created_at: 1, content: "", tags: [["relay", "wss://vault.local/feed"], ["challenge", ch]] }, device)
  const client = new HavenClient(boxConn("/feed", { signer, Socket, loc }), { auth, timeoutMs: 2000 })
  const evs = await client.query({ kinds: [1], limit: 1 })
  assert.deepEqual(evs.map(e => e.content), ["from ws://box.lan:8080/feed"])
  const sentAuth = sockets[0].sent.find(m => m[0] === "AUTH")[1]
  assert.equal(sentAuth.pubkey, getPublicKey(owner), "signed by the owner, not the page's device key")
  assert.ok(sockets[0].authed)
})

test("a box that refuses the AUTH (not its owner) fails the read; nothing hangs", async () => {
  const { Socket } = fakeRelay({ owner: "f".repeat(64) })
  const auth = ch => finalizeEvent({ kind: 22242, created_at: 1, content: "", tags: [["challenge", ch]] }, device)
  const client = new HavenClient(boxConn("/", { signer, Socket, loc }), { auth, timeoutMs: 2000 })
  await assert.rejects(client.query({ kinds: [1] }), /refused AUTH/)
})

test("startBoxVault: the vault's shape, one socket per route, stop closes them", async () => {
  const { Socket, sockets } = fakeRelay()
  const routeClient = (haven, route) => ({ route, conn: haven.conn(`ui${route}`, { route }) })
  const v = startBoxVault({ signer, routeClient, deviceKey: () => device, Socket, loc })
  assert.equal(v.box, true)
  assert.deepEqual([v.outbox.route, v.feed.route, v.inbox.route], ["/", "/feed", "/inbox"])
  assert.deepEqual(sockets.map(s => s.url), ["ws://box.lan:8080/", "ws://box.lan:8080/feed", "ws://box.lan:8080/inbox"])
  let closed = 0
  for (const c of [v.outbox.conn, v.feed.conn, v.inbox.conn]) c.onClose(() => closed++)
  await v.haven.stop()
  assert.equal(closed, 3)
  // Another caller's conn (dms.js /chat) works the same way.
  assert.equal(boxHaven({ signer, Socket, loc }).conn("chat", { route: "/chat" }).url, "ws://box.lan:8080/chat")
})

test("box API calls carry a valid NIP-98 owner token: URL, method, and the body's hash", async () => {
  const seen = []
  const box = mockBox({ now: () => 1_800_000_000_000 })
  const fetchImpl = async (url, init) => { seen.push({ url, init }); return box(url, init) }
  const api = boxApi({ signer, base: "http://box.lan:8080/api/box", fetchImpl })
  const st = await api.status()
  assert.equal(st.version, "1.0.0")
  const moved = await api.move("/mnt/disk/nostr-vault")
  assert.equal(moved.path, "/mnt/disk/nostr-vault")
  for (const { url, init } of seen) {
    const ev = await unpackEventFromToken(init.headers.Authorization)
    assert.equal(ev.pubkey, getPublicKey(owner))
    assert.ok(await validateEvent(ev, url, init.method, init.body ? JSON.parse(init.body) : undefined), `${init.method} ${url}`)
  }
  assert.ok(seen[1].init.body && seen[1].init.headers["Content-Type"] === "application/json")
})

test("box API: a read-only sign-in can't manage the box; a refusal says why", async () => {
  await assert.rejects(boxApi({ signer: { readOnly: true }, base: "http://b/api/box", fetchImpl: mockBox() }).status(), /Sign in as the box's owner/)
  const refuse = async () => new Response(JSON.stringify({ error: "owner only" }), { status: 403 })
  await assert.rejects(boxApi({ signer, base: "http://b/api/box", fetchImpl: refuse }).devices(), /Only the box's owner/)
  const bad = await boxApi({ signer, base: "http://b/api/box", fetchImpl: mockBox() }).move("relative/path").catch(e => e)
  assert.match(bad.message, /full folder path/)
})

test("formats: unknown is a dash, never 0", () => {
  assert.equal(bytes(18.4e9), "18.4 GB")
  assert.equal(bytes(undefined), "—")
  assert.equal(uptime(3 * 86400 + 4 * 3600), "3d 4h")
  assert.equal(uptime(null), "—")
  assert.equal(share(1, 0), null)
  assert.equal(ago(undefined), "never")
})
