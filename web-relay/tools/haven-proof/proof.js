// H3 proof: Haven (wasm) served over a JS byte stream, in a page or a dedicated worker.
//   loopback: havenConn(id, {mode:"nip01"}) driven directly with NDJSON
//   tcp:      the same, behind real @fips/tcp on port 7447 with the owner gate, over an in-memory fabric
// Phase 1 writes the owner's note; phase 2 runs after a reload (new Go runtime, same IndexedDB) and reads it back.
import { FipsTcpEndpoint } from "@fips/tcp"
import { getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { hexToBytes } from "@noble/hashes/utils.js"
import { ownerGatedEndpoint, RELAY_SERVICE_PORT } from "../../src/fips/tcp-server.js"
import { parseOwners } from "../../src/fips/owners.js"
import { fabric } from "./fabric.js"

const enc = new TextEncoder()
const sleep = ms => new Promise(r => setTimeout(r, ms))

export async function runProof({ phase, ownerSk, strangerSk, noteId, havenEnv = {}, stub }) {
  const checks = []
  const check = (name, pass, detail = "") => checks.push({ name, pass: !!pass, detail: String(detail).slice(0, 400) })
  const t = { start: performance.now() }
  const owner = hexToBytes(ownerSk), stranger = hexToBytes(strangerSk)
  const ownerPk = getPublicKey(owner)
  const data = { context: typeof window === "undefined" ? "worker" : "page", ownerPk }

  try {
    if (stub) (await import("./stub.js")).installStub()
    else await loadHaven(data)
    t.loaded = performance.now()
    await globalThis.havenStart({ ownerNpub: npubEncode(ownerPk), env: havenEnv })
    t.started = performance.now()
    check("havenStart resolves", true)
    data.ms = { load: Math.round(t.loaded - t.start), start: Math.round(t.started - t.loaded) }

    let nextId = phase * 1000
    if (phase === 1) {
      // Loopback: write, read, policy, framing.
      const a = conn(nextId++)
      const note = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content: "h3 loopback " + Date.now() }, owner)
      data.noteId = note.id
      a.send(["EVENT", note])
      const ok = await a.until(l => l[0] === "OK" && l[1] === note.id)
      check("loopback: owner EVENT -> OK true", ok?.[2] === true, JSON.stringify(ok))

      a.send(["REQ", "q1", { ids: [note.id] }])
      const eose = await a.until(l => l[0] === "EOSE" && l[1] === "q1")
      const got = a.lines.filter(l => l[0] === "EVENT" && l[1] === "q1").map(l => l[2].id)
      check("loopback: REQ ids -> the note + EOSE", eose && got.length === 1 && got[0] === note.id, JSON.stringify(got))

      const foreign = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content: "not the owner" }, stranger)
      a.send(["EVENT", foreign])
      const ok2 = await a.until(l => l[0] === "OK" && l[1] === foreign.id)
      check("loopback: stranger EVENT on / -> OK false", ok2?.[2] === false, JSON.stringify(ok2))

      const forged = { ...note, content: "tampered" }
      a.send(["EVENT", forged])
      const ok3 = await a.until(l => l[0] === "OK" && l[1] === forged.id && l !== ok)
      check("loopback: forged EVENT -> OK false", ok3?.[2] === false, JSON.stringify(ok3))

      // One line split across three writes, then two lines in one write.
      const line = enc.encode(JSON.stringify(["REQ", "split", { ids: [note.id] }]) + "\n")
      a.c.write(line.subarray(0, 5)); await sleep(20)
      a.c.write(line.subarray(5, 40)); await sleep(20)
      a.c.write(line.subarray(40))
      check("loopback: line split across writes", await a.until(l => l[0] === "EOSE" && l[1] === "split"))
      a.c.write(enc.encode(JSON.stringify(["REQ", "p1", { ids: [note.id] }]) + "\n" + JSON.stringify(["REQ", "p2", { ids: [note.id] }]) + "\n"))
      const p1 = await a.until(l => l[0] === "EOSE" && l[1] === "p1")
      const p2 = await a.until(l => l[0] === "EOSE" && l[1] === "p2")
      check("loopback: two lines in one write", p1 && p2)

      // Live subscription: a second connection's write reaches the first one's open REQ.
      a.send(["REQ", "live", { kinds: [1], authors: [ownerPk], since: note.created_at }])
      await a.until(l => l[0] === "EOSE" && l[1] === "live")
      const b = conn(nextId++)
      const later = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000) + 1, tags: [], content: "live " + Date.now() }, owner)
      b.send(["EVENT", later])
      await b.until(l => l[0] === "OK" && l[1] === later.id)
      check("loopback: live EVENT reaches another connection's REQ", await a.until(l => l[0] === "EVENT" && l[1] === "live" && l[2].id === later.id))

      a.c.close()
      check("loopback: close() fires onClose", await a.untilClosed())
      b.c.close()
    } else {
      // After reload: the note written in phase 1 must come back from IndexedDB.
      const a = conn(nextId++)
      a.send(["REQ", "persist", { ids: [noteId] }])
      const eose = await a.until(l => l[0] === "EOSE" && l[1] === "persist")
      const got = a.lines.filter(l => l[0] === "EVENT" && l[1] === "persist").map(l => l[2].id)
      check("reload: phase-1 note served from IndexedDB", eose && got[0] === noteId, JSON.stringify(got))
      a.c.close()
    }

    // TCP over FIPS on 7447, owner gate in front of havenConn.
    await tcpChecks({ phase, owner, stranger, ownerPk, noteId: noteId ?? data.noteId, check, data, nextId: phase * 1000 + 500 })

    await globalThis.havenStop()
    check("havenStop resolves", true)
  } catch (e) {
    check("no exception", false, e?.stack ?? e)
  }
  data.ms = { ...data.ms, total: Math.round(performance.now() - t.start) }
  return { ok: checks.every(c => c.pass), checks, data }
}

async function loadHaven(data) {
  if (!globalThis.Go) (0, eval)(await (await fetch("/wasm_exec.js")).text())
  const go = new globalThis.Go()
  const t0 = performance.now()
  const { instance } = await WebAssembly.instantiateStreaming(fetch("/haven.wasm"), go.importObject)
  data.instantiateMs = Math.round(performance.now() - t0)
  go.run(instance).then(() => (globalThis.__havenExited = true))
  for (let i = 0; i < 500 && typeof globalThis.havenStart !== "function"; i++) await sleep(10)
  if (typeof globalThis.havenStart !== "function") throw new Error("havenStart never appeared on globalThis")
}

// One havenConn in nip01 mode with a line collector.
function conn(id, opts = { mode: "nip01", route: "/" }) {
  const c = globalThis.havenConn(id, opts)
  const lines = []
  const dec = new TextDecoder()
  let buf = "", closed = false
  c.onData(b => {
    buf += dec.decode(b, { stream: true })
    for (let i; (i = buf.indexOf("\n")) >= 0; buf = buf.slice(i + 1)) lines.push(JSON.parse(buf.slice(0, i)))
  })
  c.onClose(() => (closed = true))
  const until = async (pred, ms = 10000) => {
    for (const end = Date.now() + ms; Date.now() < end; await sleep(10)) {
      const hit = lines.find(pred)
      if (hit) return hit
    }
  }
  const untilClosed = async (ms = 5000) => {
    for (const end = Date.now() + ms; Date.now() < end && !closed; ) await sleep(10)
    return closed
  }
  return { c, lines, until, untilClosed, send: m => c.write(enc.encode(JSON.stringify(m) + "\n")) }
}

async function tcpChecks({ phase, owner, stranger, ownerPk, noteId, check, data, nextId }) {
  const net = fabric()
  const relayKey = "02" + getPublicKey(hexToBytes("1".repeat(64)))
  const owners = parseOwners(ownerPk)
  let rejected = 0, accepted = 0
  const server = new FipsTcpEndpoint(ownerGatedEndpoint(net.endpoint(relayKey), () => owners, () => rejected++), RELAY_SERVICE_PORT)
  const conns = new Map()

  // Minimal server pump: TCP bytes <-> havenConn bytes. The page's real pump lives in tcp-server.js.
  const serverTick = async now => {
    await server.poll(now)
    for (let id; (id = await server.accept()) !== undefined; ) {
      accepted++
      const s = { hc: globalThis.havenConn(nextId++, { mode: "nip01", route: "/" }), out: [] }
      s.hc.onData(b => s.out.push(b.slice()))
      s.hc.onClose(() => (s.closed = true))
      conns.set(id, s)
    }
    for (const [id, s] of conns) {
      if ((await server.state(id)) === undefined) { s.hc.close(); conns.delete(id); continue }
      for (let chunk; (chunk = await server.read(id, 65536, now)).length; ) s.hc.write(chunk)
      while (s.out.length) {
        const n = await server.write(id, s.out[0], now)
        if (n < s.out[0].length) { s.out[0] = s.out[0].subarray(n); break }
        s.out.shift()
      }
    }
  }

  const client = async sk => {
    const ep = new FipsTcpEndpoint(net.endpoint("02" + getPublicKey(sk)), RELAY_SERVICE_PORT)
    const id = await ep.connect(relayKey, Date.now())
    const lines = []
    let buf = ""
    const dec = new TextDecoder()
    const pump = async () => {
      const now = Date.now()
      await ep.poll(now); await serverTick(now); await net.deliver()
      if ((await ep.state(id)) === undefined) return
      for (let b; (b = await ep.read(id, 65536, now)).length; ) buf += dec.decode(b, { stream: true })
      for (let i; (i = buf.indexOf("\n")) >= 0; buf = buf.slice(i + 1)) lines.push(JSON.parse(buf.slice(0, i)))
    }
    const until = async (pred, ms = 15000) => {
      for (const end = Date.now() + ms; Date.now() < end; ) {
        await pump()
        const hit = lines.find(pred)
        if (hit) return hit
        await sleep(5)
      }
    }
    const send = async m => {
      const b = enc.encode(JSON.stringify(m) + "\n")
      for (let off = 0; off < b.length; ) { off += await ep.write(id, b.subarray(off), Date.now()); await pump() }
    }
    return { ep, id, lines, until, send, state: () => ep.state(id) }
  }

  const v = await client(owner)
  for (const end = Date.now() + 15000; Date.now() < end && (await v.state()) !== "established"; await sleep(5)) await v.until(() => false, 1)
  check(`tcp 7447: owner connection established (phase ${phase})`, (await v.state()) === "established", await v.state())
  const t0 = performance.now()
  await v.send(["REQ", "tcp", { ids: [noteId] }])
  const eose = await v.until(l => l[0] === "EOSE" && l[1] === "tcp")
  const got = v.lines.filter(l => l[0] === "EVENT" && l[1] === "tcp").map(l => l[2].id)
  data[`tcpReqMs_phase${phase}`] = Math.round(performance.now() - t0)
  check(`tcp 7447: owner REQ -> note + EOSE (phase ${phase})`, eose && got[0] === noteId, JSON.stringify(got))

  if (phase === 1) {
    const ev = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000) + 2, tags: [], content: "over tcp " + Date.now() }, owner)
    await v.send(["EVENT", ev])
    const ok = await v.until(l => l[0] === "OK" && l[1] === ev.id)
    check("tcp 7447: owner EVENT -> OK true", ok?.[2] === true, JSON.stringify(ok))

    const s = await client(stranger)
    await s.until(() => false, 2000) // SYN retransmits for 2 s; the gate must drop every one
    check("tcp 7447: stranger never accepted, gate saw its datagrams", accepted === 1 && rejected > 0 && (await s.state()) !== "established", `accepted=${accepted} rejected=${rejected} state=${await s.state()}`)
    check("tcp 7447: stranger got no lines", s.lines.length === 0, JSON.stringify(s.lines))
  }
  for (const s of conns.values()) s.hc.close()
  await server.dispose()
}
