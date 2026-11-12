// The web's live /files reader (net/file-notes-live.js): the browser vault's own /files room, AUTHed with this
// browser's mesh key (never the account's), REQ kept open, notes merged into the Media tab (blossom-gallery.js
// mergeNoteTiles). Throwaway keys only.
import { test } from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { sealMeshAuth, ownMeshHex } from "../src/net/pair-hello.js"
import { watchFileNotes, meshDevicesConfig, FILES_AUTH_RELAY } from "../src/net/file-notes-live.js"
import { mergeNoteTiles } from "../src/net/blossom-gallery.js"

const memStorage = () => {
  const m = new Map()
  return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
const owner = generateSecretKey(), phone = generateSecretKey()
const me = getPublicKey(owner)
const SHA = "ab".repeat(32), SHA2 = "cd".repeat(32)
const fileNote = (x = SHA, at = 1000, url = `https://blossom.example/${x}`) =>
  finalizeEvent({ kind: 1063, created_at: at, tags: [["x", x], ["m", "image/jpeg"], ["size", "10"], ["p", me], ...(url ? [["url", url]] : [])], content: "" }, phone)

test("the /files AUTH is signed by this browser's mesh key, for the vault's own /files, and nothing else", async () => {
  const storage = memStorage()
  const ev = await sealMeshAuth({ challenge: "ch1", storage })
  assert.equal(ev.kind, 22242)
  assert.equal(ev.pubkey, await ownMeshHex(storage))
  assert.notEqual(ev.pubkey, me)
  assert.ok(verifyEvent(ev))
  assert.deepEqual(ev.tags, [["relay", FILES_AUTH_RELAY], ["challenge", "ch1"]])
  assert.equal(FILES_AUTH_RELAY, "wss://vault.local/files")
  await assert.rejects(sealMeshAuth({ challenge: "", storage }), /challenge/)
})

test("meshDevicesConfig: this browser's mesh key as self, each paired device by npub with its role", () => {
  const self = getPublicKey(generateSecretKey()), a = getPublicKey(phone)
  const json = JSON.parse(meshDevicesConfig({ selfHex: self, owners: new Set([a]), devices: [{ hex: a, role: "phone" }] }))
  assert.deepEqual(json, { self: npubEncode(self), devices: [{ npub: npubEncode(a), role: "phone" }] })
  const byLink = JSON.parse(meshDevicesConfig({ selfHex: self, owners: new Set([a]), devices: [] }))
  assert.deepEqual(byLink.devices, [{ npub: npubEncode(a), role: "device" }], "paired by link: no role on record")
})

/** A fake havenConn: records what the page writes, lets the test send lines and close it. */
function fakeHaven() {
  const conns = []
  return {
    conns,
    conn(id, opts) {
      let data = () => {}, closed = () => {}
      const c = {
        id, opts, sent: [], open: true,
        write: b => c.sent.push(JSON.parse(new TextDecoder().decode(b))),
        onData: cb => (data = cb), onClose: cb => (closed = cb),
        close: () => { if (c.open) { c.open = false; closed() } },
        send: msg => data(new TextEncoder().encode(JSON.stringify(msg) + "\n")),
        drop: () => { c.open = false; closed() },
      }
      conns.push(c)
      return c
    },
  }
}
const manualTimers = () => {
  const due = []
  return { due, set: (f, ms) => { due.push({ f, ms }); return due.length }, clear: () => {}, run: () => due.splice(0).forEach(t => t.f()) }
}

test("watchFileNotes: answers AUTH, then keeps one REQ open on /files; notes and deletions change the tiles live", async () => {
  const haven = fakeHaven(), timers = manualTimers(), seen = []
  const stop = watchFileNotes({ haven, owner: me, auth: ch => ({ id: "auth-" + ch, kind: 22242 }), onChange: t => seen.push(t), timers })
  const c = haven.conns[0]
  assert.deepEqual(c.opts, { mode: "nip01", route: "/files", owner: true })
  c.send(["AUTH", "ch1"])
  await new Promise(r => setImmediate(r))
  assert.deepEqual(c.sent[0], ["AUTH", { id: "auth-ch1", kind: 22242 }])
  c.send(["OK", "auth-ch1", true, ""])
  const req = c.sent[1]
  assert.equal(req[0], "REQ")
  assert.deepEqual(req[2], { kinds: [1063, 5], "#p": [me] })
  const note = fileNote()
  c.send(["EVENT", req[1], note])
  c.send(["EOSE", req[1]])
  assert.equal(c.sent.filter(m => m[0] === "CLOSE").length, 0, "the REQ stays open after EOSE")
  assert.deepEqual(seen.at(-1).map(t => t.sha256), [SHA])
  const del = finalizeEvent({ kind: 5, created_at: 1001, tags: [["e", note.id], ["k", "1063"], ["x", SHA]], content: "" }, phone)
  c.send(["EVENT", req[1], del])
  assert.deepEqual(seen.at(-1), [])
  c.send(["EVENT", req[1], note])
  assert.deepEqual(seen.at(-1), [], "a note replayed after its deletion stays gone")
  stop()
  assert.equal(c.open, false)
})

test("watchFileNotes: a dropped stream comes back after a pause and asks from the newest note seen, less the overlap", async () => {
  const haven = fakeHaven(), timers = manualTimers()
  const stop = watchFileNotes({ haven, owner: me, auth: ch => ({ id: "a" + ch }), onChange: () => {}, timers, retryMs: 5000 })
  let c = haven.conns[0]
  c.send(["AUTH", "x"]); await new Promise(r => setImmediate(r)); c.send(["OK", "ax", true, ""])
  c.send(["EVENT", c.sent[1][1], fileNote(SHA, 5000)])
  c.drop()
  assert.equal(haven.conns.length, 1, "not at once")
  assert.equal(timers.due[0].ms, 5000)
  timers.run()
  c = haven.conns[1]
  assert.notEqual(c.id, haven.conns[0].id, "a new stream id: Haven refuses one still open")
  c.send(["AUTH", "y"]); await new Promise(r => setImmediate(r)); c.send(["OK", "ay", true, ""])
  assert.equal(c.sent[1][2].since, 5000 - 600)
  stop()
  c.drop()
  assert.equal(timers.due.length, 0, "stopped: no reconnect")
})

test("watchFileNotes: a refused AUTH or REQ (an older vault, a key it doesn't take) stops quietly, no retry loop", async () => {
  const haven = fakeHaven(), timers = manualTimers(), seen = []
  watchFileNotes({ haven, owner: me, auth: ch => ({ id: "a" + ch }), onChange: t => seen.push(t), timers })
  const c = haven.conns[0]
  c.send(["AUTH", "x"]); await new Promise(r => setImmediate(r))
  c.send(["OK", "ax", false, "restricted: no"])
  assert.equal(c.open, false)
  assert.equal(timers.due.length, 0)
  const h2 = fakeHaven()
  watchFileNotes({ haven: h2, owner: me, auth: ch => ({ id: "a" + ch }), onChange: () => {}, timers })
  const d = h2.conns[0]
  d.send(["AUTH", "x"]); await new Promise(r => setImmediate(r)); d.send(["OK", "ax", true, ""])
  d.send(["CLOSED", d.sent[1][1], "restricted: media notes are read by this vault's owner and paired devices only"])
  assert.equal(d.open, false)
  assert.equal(timers.due.length, 0)
  assert.deepEqual(seen, [])
})

test("watchFileNotes: no live Haven (box mode, a vault still starting) opens nothing", () => {
  assert.equal(typeof watchFileNotes({ haven: null, owner: me, auth: () => ({}), onChange: () => {} }), "function")
  assert.equal(typeof watchFileNotes({ haven: { conn() {} }, owner: "", auth: () => ({}), onChange: () => {} }), "function")
})

test("mergeNoteTiles: a note-only file joins the grid as new, a file the servers list is left as listed, a note with no https link is left out", () => {
  const listed = [{ sha256: SHA2, url: `https://s.example/${SHA2}`, type: "image/png", size: 1, uploaded: 50, kind: "photo", servers: ["https://s.example"] }]
  const tiles = [
    { sha256: SHA, mime: "video/mp4", size: 99, createdAt: 900, urls: [`https://b.example/${SHA}.mp4`] },
    { sha256: SHA2, mime: "image/png", size: 1, createdAt: 60, urls: [`https://other.example/${SHA2}`] },
    { sha256: "ef".repeat(32), mime: "image/jpeg", size: 5, createdAt: 70, urls: [] },
  ]
  const all = mergeNoteTiles(listed, tiles)
  assert.deepEqual(all.map(b => b.sha256), [SHA, SHA2])
  assert.deepEqual(all[0], { sha256: SHA, url: `https://b.example/${SHA}.mp4`, type: "video/mp4", size: 99, uploaded: 900, kind: "video", servers: [], fromNote: true })
  assert.equal(all[1], listed[0])
  assert.equal(mergeNoteTiles(listed, []), listed)
})
