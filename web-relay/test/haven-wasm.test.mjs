// The real haven.wasm under node (Haven picks its memstore there), driven through the same client and
// TCP/FIPS server the page uses. Skipped until tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { randomBytes } from "node:crypto"
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

test("real Haven: a stream reports buffered() and closes on a line over the Go cap", { skip: !built && "public/haven.wasm not built" }, async () => {
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(generateSecretKey())) })
  const s = h.conn("cap", { mode: "nip01", route: "/" })
  assert.equal(typeof s.buffered, "function", "the page's read backpressure needs buffered()")
  assert.equal(typeof s.buffered(), "number")
  const closed = new Promise(r => s.onClose(r))
  s.write(new Uint8Array(300_000).fill(0x61))
  assert.equal(s.buffered(), 300_000, "an unterminated line counts as buffered")
  s.write(new Uint8Array(300_000).fill(0x61))
  assert.equal(await closed, "line too long")
  assert.equal(s.buffered(), 0)
  await h.stop()
})

// The vault app pushes the owner's notes over the owner's mesh stream, signed with the owner's Nostr account
// (BrowserRelaySender), while the owner list holds only the vault's mesh address. Haven checks the author.
test("real Haven: the owner's account notes are kept once the account is saved, refused before", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { havenAuthors } = await import("../src/fips/owners.js")
  const mesh = getPublicKey(generateSecretKey()), test = getPublicKey(generateSecretKey()), account = generateSecretKey()
  const h = await boot()
  for (const [saved, kept] of [[undefined, false], [getPublicKey(account), true]]) {
    await h.start({ ...havenAuthors({ owners: new Set([mesh]), account: saved, extra: [test] }), storePrefix: `acct-${kept}` })
    const c = new HavenClient(h.conn(`acct-${kept}`, { mode: "nip01", route: "/" }))
    const r = await c.event(note(account, "pushed from the phone"))
    assert.equal(r.ok, kept, kept ? "account saved: the owner's note is kept" : "no account saved: refused, as before the fix")
    c.close()
    await h.stop()
  }
})

// The web Vault tab keeps what others sent the user in /inbox. The inbox asks a writer to AUTH before it takes an
// event (MustNotBeBlacklistedToPost), and the client used to answer AUTH for reads only, so every write was refused
// and each visit started empty.
test("real Haven: /inbox keeps others' replies, likes, zaps and follow lists once the page's stream AUTHs", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { makeAuthEvent } = await import("nostr-tools/nip42")
  const owner = generateSecretKey(), device = generateSecretKey(), stranger = generateSecretKey()
  const me = getPublicKey(owner)
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(me), whitelist: [npubEncode(getPublicKey(device))], env: { RELAY_URL: "vault.local" }, storePrefix: "inbox-auth" })
  const auth = ch => finalizeEvent(makeAuthEvent("wss://vault.local/inbox", ch), device)
  const c = new HavenClient(h.conn("ui-inbox", { mode: "nip01", route: "/inbox", owner: true }), { auth })
  const now = Math.floor(Date.now() / 1000), mine = note(owner, "mine")
  const ev = (kind, tags, content = "") => finalizeEvent({ kind, created_at: now, tags, content }, stranger)
  const sent = [ev(1, [["e", mine.id], ["p", me]], "a reply"), ev(7, [["e", mine.id], ["p", me]], "+"), ev(9735, [["e", mine.id], ["p", me]]), ev(3, [["p", me]])]
  for (const e of sent) assert.deepEqual(await c.event(e), { ok: true, message: "" }, `kind ${e.kind} kept`)
  assert.equal((await c.query({ kinds: [1, 3, 7, 9735], "#p": [me] })).length, 4)
  c.close()
  const anon = new HavenClient(h.conn("no-auth", { mode: "nip01", route: "/inbox", owner: true }))
  assert.match((await anon.event(ev(1, [["p", me]], "x"))).message, /^auth-required/, "no auth callback: refused, not retried")
  anon.close()
  await h.stop()
})

test("real Haven: /files takes a paired device's file note and serves it to the page's mesh-key AUTH, never to an account key", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { makeAuthEvent } = await import("nostr-tools/nip42")
  const owner = generateSecretKey(), device = generateSecretKey(), mesh = generateSecretKey(), phone = generateSecretKey(), stranger = generateSecretKey()
  const me = getPublicKey(owner)
  const h = await boot()
  await h.start({
    ownerNpub: npubEncode(me), whitelist: [npubEncode(getPublicKey(device))], env: { RELAY_URL: "vault.local" }, storePrefix: "files-live",
    meshDevices: JSON.stringify({ self: npubEncode(getPublicKey(mesh)), devices: [{ npub: npubEncode(getPublicKey(phone)), role: "phone" }] }),
  })
  const as = sk => ch => finalizeEvent(makeAuthEvent("wss://vault.local/files", ch), sk)
  const open = (id, sk) => new HavenClient(h.conn(id, { mode: "nip01", route: "/files", owner: true }), { auth: as(sk) })
  const now = Math.floor(Date.now() / 1000)
  const fileNote = sk => finalizeEvent({ kind: 1063, created_at: now, tags: [["x", "ab".repeat(32)], ["m", "image/jpeg"], ["size", "1234"], ["p", me], ["url", "https://blossom.example/" + "ab".repeat(32)]], content: "" }, sk)
  const filter = { kinds: [1063, 5], "#p": [me] }

  try {
  const page = open("ui-files", mesh)
  assert.deepEqual(await page.query(filter), [], "the page's own stream reaches /files and its mesh key may read")
  const sender = open("phone-files", phone)
  assert.deepEqual(await sender.event(fileNote(phone)), { ok: true, message: "" }, "a paired device writes")
  assert.match((await sender.event(fileNote(stranger))).message, /^restricted/, "an unpaired key does not")
  const got = await page.query(filter)
  assert.equal(got.length, 1)
  assert.equal(got[0].pubkey, getPublicKey(phone))
  const byDevice = open("device-files", device)
  await assert.rejects(byDevice.query(filter), /restricted/, "the whitelisted device key never reads /files")
  for (const c of [page, sender, byDevice]) c.close()
  } finally { await h.stop() }
})

test("real Haven: a start without meshDevices forgets the last one's paired devices", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { makeAuthEvent } = await import("nostr-tools/nip42")
  const owner = generateSecretKey(), mesh = generateSecretKey()
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(owner)), env: { RELAY_URL: "vault.local" }, storePrefix: "files-forget" })
  const c = new HavenClient(h.conn("ui-files", { mode: "nip01", route: "/files", owner: true }), { auth: ch => finalizeEvent(makeAuthEvent("wss://vault.local/files", ch), mesh) })
  await assert.rejects(c.query({ kinds: [1063] }), /restricted/, "the earlier start's mesh key is not this one's")
  c.close()
  await h.stop()
})

/** A websocket client over one havenConn stream, enough for NIP-01: masked text frames out, unmasked frames in. */
function meshWs(stream, path, host) {
  const frames = [], waiters = []
  let buf = Buffer.alloc(0), open = false, opened
  const ready = new Promise((res, rej) => { opened = { res, rej } })
  const push = msg => { const w = waiters.shift(); w ? w(msg) : frames.push(msg) }
  stream.onData(b => {
    buf = Buffer.concat([buf, Buffer.from(b)])
    if (!open) {
      const end = buf.indexOf("\r\n\r\n")
      if (end < 0) return
      const head = buf.subarray(0, end).toString("latin1")
      buf = buf.subarray(end + 4)
      if (!/^HTTP\/1\.1 101/.test(head)) return opened.rej(new Error("no upgrade: " + head.split("\r\n")[0]))
      open = true
      opened.res()
    }
    for (;;) {
      if (buf.length < 2) return
      let len = buf[1] & 0x7f, off = 2
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4 }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10 }
      if (buf.length < off + len) return
      const op = buf[0] & 0x0f, body = buf.subarray(off, off + len)
      buf = buf.subarray(off + len)
      if (op === 1) push(JSON.parse(body.toString("utf8")))
    }
  })
  stream.onClose(() => { opened.rej(new Error("closed before upgrade")); while (waiters.length) waiters.shift()(null) })
  stream.write(Buffer.from(`GET ${path} HTTP/1.1\r\nHost: ${host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${randomBytes(16).toString("base64")}\r\nSec-WebSocket-Version: 13\r\n\r\n`))
  const send = msg => {
    const body = Buffer.from(JSON.stringify(msg)), mask = randomBytes(4)
    const head = body.length < 126 ? Buffer.from([0x81, 0x80 | body.length])
      : Buffer.concat([Buffer.from([0x81, 0x80 | 126]), Buffer.from([body.length >> 8, body.length & 0xff])])
    stream.write(Buffer.concat([head, mask, Buffer.from(body.map((c, i) => c ^ mask[i % 4]))]))
  }
  const next = () => frames.length ? Promise.resolve(frames.shift()) : new Promise(r => waiters.push(r))
  /** The next frame whose type is one of `types`, skipping others. */
  const until = async (...types) => { for (;;) { const m = await next(); if (!m || types.includes(m[0])) return m } }
  return { ready, send, until }
}

test("real Haven: a paired phone AUTHs /files over the mesh door and writes; an unpaired key is refused", { skip: !built && "public/haven.wasm not built" }, async () => {
  const { makeAuthEvent } = await import("nostr-tools/nip42")
  const owner = generateSecretKey(), mesh = generateSecretKey(), phone = generateSecretKey(), stranger = generateSecretKey()
  const me = getPublicKey(owner), meshNpub = npubEncode(getPublicKey(mesh))
  const h = await boot()
  // As web-vault startVault starts it: HAVEN_MESH_NPUB is what a mesh AUTH must name (haven-go meshAuthURL).
  await h.start({
    ownerNpub: npubEncode(me), env: { RELAY_URL: "vault.local", HAVEN_MESH_NPUB: meshNpub }, storePrefix: "files-mesh",
    meshDevices: JSON.stringify({ self: meshNpub, devices: [{ npub: npubEncode(getPublicKey(phone)), role: "phone" }] }),
  })
  const now = Math.floor(Date.now() / 1000)
  const fileNote = sk => finalizeEvent({ kind: 1063, created_at: now, tags: [["x", "cd".repeat(32)], ["m", "image/jpeg"], ["size", "99"], ["p", me], ["url", "https://blossom.example/" + "cd".repeat(32)]], content: "" }, sk)
  const overMesh = async (id, sk) => {
    const ws = meshWs(h.conn(id, { mode: "mesh", peer: getPublicKey(sk) }), "/files", `${meshNpub}.fips`)
    await ws.ready
    const [, challenge] = await ws.until("AUTH")
    const auth = finalizeEvent(makeAuthEvent(`ws://${meshNpub}.fips/files`, challenge), sk)
    ws.send(["AUTH", auth])
    return { ws, authOk: await ws.until("OK") }
  }

  try {
    const fromPhone = await overMesh("mesh-phone", phone)
    assert.equal(fromPhone.authOk[2], true, "the paired phone's mesh AUTH: " + fromPhone.authOk[3])
    const note = fileNote(phone)
    fromPhone.ws.send(["EVENT", note])
    assert.deepEqual(await fromPhone.ws.until("OK"), ["OK", note.id, true, ""], "the phone writes its file note over the mesh")

    const fromStranger = await overMesh("mesh-stranger", stranger)
    const bad = fileNote(stranger)
    fromStranger.ws.send(["EVENT", bad])
    const refused = await fromStranger.ws.until("OK")
    assert.equal(refused[2], false, "an unpaired key never writes /files over the mesh")

    const page = new HavenClient(h.conn("ui-files-mesh", { mode: "nip01", route: "/files", owner: true }), { auth: ch => finalizeEvent(makeAuthEvent("wss://vault.local/files", ch), mesh) })
    const got = await page.query({ kinds: [1063], "#p": [me] })
    assert.deepEqual(got.map(e => e.id), [note.id], "the page sees the phone's note, not the stranger's")
    page.close()
  } finally { await h.stop() }
})
