// The relay's TCP pumps (src/fips/pump.js): 50 Hz / 20 Hz while a connection is open, IDLE_MS when none is, and a
// datagram wakes an idle pump at once. The relay used to tick 70 times a second for its whole life, idle or not.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { Segment, FlagSet, Flags } from "@fips/tcp"
import { pollPump, IDLE_MS } from "../src/fips/pump.js"
import { MeshDoorServer } from "../src/fips/mesh-door.js"
import { encodeShim, meshAddress, SHIM_PORT } from "../src/fips/ipv6-shim.js"
import { POLL_MS_LIMITS } from "./support/idle-limits.mjs"

const wait = ms => new Promise(r => setTimeout(r, ms))

test("idle pumps are slow, a datagram wakes one at once, and a connected one keeps its fast tick", async () => {
  assert.ok(IDLE_MS >= 250 && IDLE_MS <= 1000, `idle tick ${IDLE_MS} ms`)
  assert.deepEqual(POLL_MS_LIMITS, { tcp: 50, door: 20, idle: IDLE_MS }, "the slow tick is the one both servers use")

  let starts = 0, busy = false
  const pump = pollPump(() => { starts++ }, () => busy, 20)
  try {
    pump.start()
    await wait(80) // idle: 4 ticks a 20 ms period used to go here
    assert.ok(starts <= 1, `idle: ${starts} ticks in 80 ms, used to be 4`)
    pump.wake()
    await wait(20)
    assert.equal(starts, 1, "a datagram ticks at once, not up to IDLE_MS later")

    busy = true // a connection it accepted: the fast tick comes back
    pump.wake()
    await wait(20)
    const from = starts
    await wait(90)
    assert.ok(starts - from >= 2, `connected: ${starts - from} ticks in 90 ms at a 20 ms period`)
  } finally { pump.stop() }
})

test("stop() ends it, no two ticks overlap, and a wake during a tick is not lost", async () => {
  let starts = 0, running = 0, peak = 0
  const pump = pollPump(async () => { starts++; running++; peak = Math.max(peak, running); await wait(30); running-- }, () => true, 5)
  try {
    pump.start()
    await wait(50)
    assert.equal(peak, 1, "ticks never overlap")
    assert.ok(starts >= 1)
    pump.wake() // asked for while a tick is running: one more runs after it
    const withWake = starts
    await wait(80)
    assert.ok(starts > withWake, "the wake ran")
    pump.stop()
    const stoppedAt = starts
    await wait(80)
    assert.equal(starts, stoppedAt, "nothing new after stop()")
  } finally { pump.stop() }
})

// The mesh door's own wiring: a segment from a peer wakes the pump (the relay used to wait for the next 20 ms tick,
// now up to IDLE_MS, so a wake on arrival is what keeps a connection's first segment instant).
test("the mesh door wakes its pump on a segment from a peer", async () => {
  const peer = getPublicKey(generateSecretKey()), self = getPublicKey(generateSecretKey())
  const listeners = new Map()
  const node = { on(t, f) { listeners.set(t, f); return () => {} }, sendDatagram: async () => {} }
  const door = new MeshDoorServer(node, self, { conn: () => ({ write() {}, onData() {}, onClose() {}, close() {} }) })
  let ticks = 0
  const tick = door.tick.bind(door)
  door.tick = async () => { ticks++; return tick() }
  door.start()
  try {
    await wait(600) // idle: one slow tick, not 30
    assert.ok(ticks <= 1, `door idle: ${ticks} ticks in 600 ms at 20 ms used to be 30`)
    const syn = new Segment({ srcPort: 80, dstPort: 80, seq: 1, flags: new FlagSet(Flags.Syn), window: 65535 }).encode()
    const payload = encodeShim(syn, meshAddress(peer), meshAddress(self))
    const from = ticks
    await listeners.get("datagram")({ dstPort: SHIM_PORT, srcPort: SHIM_PORT, src: "02" + peer, payload })
    await wait(30)
    assert.equal(ticks - from, 1, "the arriving segment ticked it at once")
  } finally { await door.stop() }
})
