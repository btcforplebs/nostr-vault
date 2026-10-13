// NIP-01 over TCP/FIPS on one FSP service port, served by Haven. Only owner identities get past the
// datagram gate, so a stranger's SYN is dropped before the TCP stack sees it (no SYN-ACK, no RST).
// Wire: NDJSON, one NIP-01 JSON array per "\n"-terminated line. Each TCP connection becomes one Haven
// stream in "nip01" mode on the outbox route; the page picks the route, the stream can't.
import { FipsTcpEndpoint } from "@fips/tcp"
import { isOwner, xOnly } from "./owners.js"

export const RELAY_SERVICE_PORT = 7447
const POLL_MS = 50
const READ_CHUNK = 64 * 1024
const MAX_PENDING_OUT = 4 * 1024 * 1024
// Inbound bytes without a "\n" before the stream is aborted. Haven's own 512000-byte message cap sits on
// its ws conn, below the NDJSON reassembly, so it never sees an unterminated line; this is that cap here.
export const MAX_LINE_IN = 512_000
// One owner device must not hold every slot and starve the owner's others.
export const MAX_CONNECTIONS_PER_PEER = 4
const MAX_CONNECTIONS = 64
export const HAVEN_ROUTE = "/"
// After we close our side, a peer that never finishes its own close is reset after this long.
const CLOSE_GRACE_MS = 5_000

/** Wrap a FIPS datagram endpoint so service handlers only ever see datagrams from owners. */
export function ownerGatedEndpoint(endpoint, getOwners, onReject = () => {}, onDrop = () => {}) {
  return {
    registerService(port, handler) {
      return endpoint.registerService(port, async ctx => {
        if (!isOwner(getOwners(), ctx.src)) return onReject(ctx)
        // The TCP stack throws on a segment it refuses (an owner's SYN past the connection limits). Drop it
        // here: @fips/core doesn't catch service handler errors.
        try {
          await handler(ctx)
        } catch (e) {
          onDrop(ctx, e)
        }
      })
    },
    sendDatagram: args => endpoint.sendDatagram(args),
  }
}

export class TcpFipsRelayServer {
  /**
   * @param endpoint  FipsNode (or any FipsDatagramEndpoint)
   * @param haven     { conn(id, opts) -> { write, onData, onClose, close } }, see src/haven/haven.js
   * @param getOwners () => Set<x-only hex>
   * clock must be Date.now-based: FipsTcpEndpoint stamps inbound segments with Date.now() itself.
   */
  constructor(endpoint, haven, getOwners, { port = RELAY_SERVICE_PORT, clock = () => Date.now(), tcpConfig } = {}) {
    this.stats = { rejectedDatagrams: 0, droppedSegments: 0, accepted: 0, open: 0, lastInAt: 0 }
    this.clock = clock
    this.haven = haven
    this.conns = new Map()
    const gated = ownerGatedEndpoint(endpoint, getOwners, () => this.stats.rejectedDatagrams++, () => this.stats.droppedSegments++)
    this.tcp = new FipsTcpEndpoint(gated, port, { maxConnections: MAX_CONNECTIONS, maxConnectionsPerPeer: MAX_CONNECTIONS_PER_PEER, ...tcpConfig })
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
  }

  /** One pump: timers, new connections, reads, writes, teardown. Safe to call directly in tests. */
  async tick() {
    if (this.busy) return
    this.busy = true
    try {
      const now = this.clock()
      await this.tcp.poll(now)
      for (let id; (id = await this.tcp.accept()) !== undefined; ) await this.#add(id)
      for (const c of [...this.conns.values()]) {
        // One connection's failure must not stop the pump for the others.
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

  async #add(id) {
    // Haven's rate limiters key on peer, so every connection from one vault shares a bucket. Without a peer
    // they would key on the per-connection id and get a fresh bucket each reconnect. Not an owner stream.
    const peer = xOnly(await this.tcp.peer(id))
    if (!peer) return this.tcp.abort(id)
    const c = { id, out: [], outBytes: 0, lineBytes: 0, stream: undefined, havenClosed: false }
    // A distinct id per TCP connection, so Haven can tell streams apart (logs).
    c.stream = this.haven.conn(`fips-${id}`, { mode: "nip01", route: HAVEN_ROUTE, peer })
    c.stream.onData(b => {
      c.out.push(b)
      c.outBytes += b.length
    })
    c.stream.onClose(() => (c.havenClosed = true))
    this.conns.set(id, c)
    this.stats.accepted++
  }

  async #pump(c, now) {
    // The stack forgets a connection once its close completes; reading it after that throws.
    if ((await this.tcp.state(c.id)) === undefined) return this.#drop(c, false)
    for (let chunk; (chunk = await this.tcp.read(c.id, READ_CHUNK, now)).length; ) {
      this.stats.lastInAt = this.clock()
      const first = chunk.indexOf(0x0a)
      if (c.lineBytes + (first < 0 ? chunk.length : first) > MAX_LINE_IN) return this.#drop(c, true)
      c.lineBytes = first < 0 ? c.lineBytes + chunk.length : chunk.length - chunk.lastIndexOf(0x0a) - 1
      c.stream.write(chunk)
    }
    while (c.out.length) {
      const head = c.out[0]
      const n = await this.tcp.write(c.id, head, now)
      c.outBytes -= n
      if (n < head.length) {
        c.out[0] = head.subarray(n)
        break
      }
      c.out.shift()
    }
    const state = await this.tcp.state(c.id)
    if (c.outBytes > MAX_PENDING_OUT) return this.#drop(c, true)
    if (state === undefined) return this.#drop(c, false)
    // Close our side once everything is flushed and either the vault finished sending or Haven hung up.
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
