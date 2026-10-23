// The page's mesh port 80, open to any FIPS peer the way a native vault's is: HTTP over real TCP in the IPv6 shim
// (./ipv6-shim.js), each connection handed whole to Haven's mesh door (haven-go mesh_door.go, through
// havenConn mode "mesh"). The door decides, with the apps' rules: a stranger can GET or HEAD only blobs a public
// note in the outbox names (mesh_safety.go, mesh_head.go), and send only the owner's own signed events. No
// queries, no other routes. Paired vaults keep their own TCP/FIPS relay on 7447 (./tcp-server.js).
import { FipsTcpEndpoint } from "@fips/tcp"
import { ipv6ShimEndpoint } from "./ipv6-shim.js"
import { xOnly } from "./owners.js"

export const MESH_DOOR_PORT = 80
const POLL_MS = 20
const READ_CHUNK = 64 * 1024
// The native door's meshMaxConns. Haven caps its side the same way and closes the extra.
export const MESH_DOOR_MAX_CONNECTIONS = 32
// Stop reading a connection while Haven holds this many of its bytes unconsumed.
const MAX_QUEUED_IN = 1024 * 1024
// A reader that takes no bytes for this long loses its slot (the native door's meshIdleWrite). Haven hands a
// response over at once, so its own send floor never sees a slow reader here: this is that floor.
export const MESH_DOOR_IDLE_WRITE_MS = 15_000
const CLOSE_GRACE_MS = 5_000

export class MeshDoorServer {
  /**
   * @param node     FipsNode (or a test node with on("datagram") + sendDatagram)
   * @param selfKey  this node's public key
   * @param haven    { conn(id, opts) }, see src/haven/haven.js
   */
  constructor(node, selfKey, haven, { clock = () => Date.now(), tcpConfig, log = m => console.warn(m) } = {}) {
    this.stats = { accepted: 0, open: 0, refused: 0, dropped: 0, idleDrops: 0, lastError: "" }
    this.clock = clock
    this.haven = haven
    this.log = log
    this.conns = new Map()
    this.shim = ipv6ShimEndpoint(node, selfKey, { allow: () => true, acceptSyn: true, onDrop: () => this.stats.dropped++ })
    this.tcp = new FipsTcpEndpoint(this.shim, MESH_DOOR_PORT, { maxConnections: MESH_DOOR_MAX_CONNECTIONS, ...tcpConfig })
    this.timer = undefined
    this.busy = false
  }

  start(intervalMs = POLL_MS) {
    this.timer ??= setInterval(() => this.tick(), intervalMs)
  }

  async stop() {
    clearInterval(this.timer)
    this.timer = undefined
    for (const c of this.conns.values()) c.stream.close()
    this.conns.clear()
    await this.tcp.dispose()
    this.shim.close()
  }

  /** One pump: timers, new connections, reads, writes, teardown. Safe to call directly in tests. */
  async tick() {
    if (this.busy) return
    this.busy = true
    try {
      const now = this.clock()
      await this.tcp.poll(now)
      for (let id; (id = await this.tcp.accept()) !== undefined; ) await this.#add(id, now)
      for (const c of [...this.conns.values()]) {
        try {
          await this.#pump(c, now)
        } catch {
          await this.#drop(c, true).catch(() => {})
        }
      }
      this.stats.open = this.conns.size
    } finally {
      this.busy = false
    }
  }

  async #add(id, now) {
    // Haven's rate limiters key on peer, so a peer's reconnects share one bucket.
    const peer = xOnly(await this.tcp.peer(id))
    const stream = peer && this.haven.conn(`mesh-${id}`, { mode: "mesh", peer })
    if (!stream || stream.error) {
      stream?.close()
      this.stats.refused++
      this.stats.lastError = String(stream?.error ?? "no peer key").slice(0, 160)
      return this.tcp.abort(id).catch(() => {})
    }
    const c = { id, stream, out: [], havenClosed: false, lastSentAt: now }
    stream.onData(b => c.out.push(b))
    stream.onClose(() => (c.havenClosed = true))
    this.conns.set(id, c)
    this.stats.accepted++
  }

  async #pump(c, now) {
    if ((await this.tcp.state(c.id)) === undefined) return this.#drop(c, false)
    const queued = () => (typeof c.stream.buffered === "function" ? c.stream.buffered() : 0)
    for (let chunk; queued() <= MAX_QUEUED_IN && (chunk = await this.tcp.read(c.id, READ_CHUNK, now)).length; ) c.stream.write(chunk)
    if (!c.out.length) c.lastSentAt = now
    while (c.out.length) {
      const head = c.out[0]
      const n = await this.tcp.write(c.id, head, now)
      if (n) c.lastSentAt = now
      if (n < head.length) {
        c.out[0] = head.subarray(n)
        break
      }
      c.out.shift()
    }
    if (c.out.length && now - c.lastSentAt > MESH_DOOR_IDLE_WRITE_MS) {
      this.stats.idleDrops++
      return this.#drop(c, true)
    }
    if ((await this.tcp.state(c.id)) === undefined) return this.#drop(c, false)
    // Close our side once everything is flushed and either the peer finished sending or Haven hung up.
    if (c.closingAt !== undefined) {
      if (now - c.closingAt > CLOSE_GRACE_MS) return this.#drop(c, true)
    } else if (!c.out.length && (c.havenClosed || (await this.tcp.isReadClosed(c.id)))) {
      c.closingAt = now
      await this.tcp.close(c.id, now)
    }
  }

  async #drop(c, abort) {
    c.stream.close()
    this.conns.delete(c.id)
    if (abort) await this.tcp.abort(c.id)
  }
}
