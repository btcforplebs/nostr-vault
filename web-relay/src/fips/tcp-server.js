// NIP-01 over TCP/FIPS on one FSP service port, served by Haven. Only owner identities get past the
// datagram gate, so a stranger's SYN is dropped before the TCP stack sees it (no SYN-ACK, no RST).
// Wire: NDJSON, one NIP-01 JSON array per "\n"-terminated line. Each TCP connection becomes one Haven
// stream in "nip01" mode on the outbox route; the page picks the route, the stream can't.
import { FipsTcpEndpoint, Segment, FlagSet, Flags } from "@fips/tcp"
import { isOwner, xOnly } from "./owners.js"

export const RELAY_SERVICE_PORT = 7447
const POLL_MS = 50
const READ_CHUNK = 64 * 1024
const MAX_PENDING_OUT = 4 * 1024 * 1024
// Inbound bytes without a "\n" before the stream is aborted. Haven's own 512000-byte message cap sits on
// its ws conn, below the NDJSON reassembly, so it never sees an unterminated line; this is that cap here.
export const MAX_LINE_IN = 512_000
// Stop reading a connection while Haven holds this many of its bytes unconsumed. The TCP receive window then
// fills and the vault stops sending, instead of Haven buffering without limit. Needs stream.buffered().
export const MAX_QUEUED_IN = 1024 * 1024
// Every owner device runs the same nsec, so one peer key is the owner's whole fleet (phone, Mac, iPad).
// The cap stops a runaway client from taking every slot, with room for the fleet working at once.
export const MAX_CONNECTIONS_PER_PEER = 16
const MAX_CONNECTIONS = 128
export const HAVEN_ROUTE = "/"
// After we close our side, a peer that never finishes its own close is reset after this long.
const CLOSE_GRACE_MS = 5_000

/** Wrap a FIPS datagram endpoint so service handlers only ever see datagrams from owners. */
export function ownerGatedEndpoint(endpoint, getOwners, onReject = () => {}, onDrop = () => {}, onReset = () => {}) {
  return {
    registerService(port, handler) {
      return endpoint.registerService(port, async ctx => {
        if (!isOwner(getOwners(), ctx.src)) return onReject(ctx)
        // The TCP stack throws on a segment it refuses (an owner's SYN past the connection limits) instead of
        // resetting it, and @fips/core doesn't catch service handler errors. Drop it here, and answer a
        // refused SYN with the RST the stack skipped, so the vault fails at once instead of retrying for minutes.
        try {
          await handler(ctx)
        } catch (e) {
          const rst = synReset(ctx.payload)
          onDrop(ctx, e, rst !== undefined)
          if (rst) await endpoint.sendDatagram({ dst: ctx.src, srcPort: port, dstPort: port, payload: rst }).then(() => onReset(ctx), () => {})
        }
      })
    },
    sendDatagram: args => endpoint.sendDatagram(args),
  }
}

/** RST|ACK bytes answering a bare SYN (RFC 9293 3.10.7.1), or undefined for any other segment. */
export function synReset(payload) {
  let seg
  try {
    seg = Segment.decode(payload)
  } catch {
    return undefined
  }
  const f = seg.flags
  if (!f.has(Flags.Syn) || f.has(Flags.Ack) || f.has(Flags.Rst)) return undefined
  const ack = (seg.seq + seg.sequenceLength()) >>> 0
  return new Segment({ srcPort: seg.dstPort, dstPort: seg.srcPort, seq: 0, ack, flags: new FlagSet(Flags.Rst | Flags.Ack), window: 0 }).encode()
}

export class TcpFipsRelayServer {
  /**
   * @param endpoint  FipsNode (or any FipsDatagramEndpoint)
   * @param haven     { conn(id, opts) -> { write, onData, onClose, close, buffered?, error? } }, see src/haven/haven.js
   * @param getOwners () => Set<x-only hex>
   * log        (msg) => void; each distinct dropped-segment error is logged once
   * clock must be Date.now-based: FipsTcpEndpoint stamps inbound segments with Date.now() itself.
   */
  constructor(endpoint, haven, getOwners, { port = RELAY_SERVICE_PORT, clock = () => Date.now(), tcpConfig, log = m => console.warn(m) } = {}) {
    this.stats = { rejectedDatagrams: 0, droppedSegments: 0, refusedSyns: 0, refusedStreams: 0, backpressured: 0, lastDropError: "", accepted: 0, open: 0, lastInAt: 0 }
    this.clock = clock
    this.haven = haven
    this.conns = new Map()
    this.log = log
    this.logged = new Set()
    // Counted before the RST goes out, so a send that hangs still shows the drop. refusedSyns counts only
    // RSTs the endpoint accepted.
    const onDrop = (ctx, e, refusedSyn) => {
      this.stats.droppedSegments++
      this.#dropped(`segment from ${xOnly(ctx.src)?.slice(0, 12) ?? "?"}${refusedSyn ? " (SYN refused, sending RST)" : ""}`, e)
    }
    const gated = ownerGatedEndpoint(endpoint, getOwners, () => this.stats.rejectedDatagrams++, onDrop, () => this.stats.refusedSyns++)
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
      for (let id; (id = await this.tcp.accept()) !== undefined; ) {
        try {
          await this.#add(id)
        } catch (e) {
          // #add closed any Haven stream it opened; only the TCP side is left.
          this.stats.refusedStreams++
          this.#dropped(id, e)
          this.conns.delete(id)
          await this.tcp.abort(id).catch(() => {})
        }
      }
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
    const stream = this.haven.conn(`fips-${id}`, { mode: "nip01", route: HAVEN_ROUTE, peer })
    try {
      // A refused havenConn doesn't throw: it returns a working, already-closed stream with an error string.
      if (stream.error) throw new Error(stream.error)
      c.stream = stream
      stream.onData(b => {
        c.out.push(b)
        c.outBytes += b.length
      })
      stream.onClose(() => (c.havenClosed = true))
      this.conns.set(id, c)
    } catch (e) {
      // Not in this.conns yet, so nothing else would ever close it.
      stream.close()
      throw e
    }
    this.stats.accepted++
  }

  async #pump(c, now) {
    // The stack forgets a connection once its close completes; reading it after that throws.
    if ((await this.tcp.state(c.id)) === undefined) return this.#drop(c, false)
    for (let chunk; !this.#backlogged(c) && (chunk = await this.tcp.read(c.id, READ_CHUNK, now)).length; ) {
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

  /** Keep the reason: stats.lastDropError, and each distinct message logged once. */
  #dropped(what, e) {
    const msg = String(e?.message ?? e).slice(0, 160)
    this.stats.lastDropError = msg
    if (this.logged.size < 32 && !this.logged.has(msg)) {
      this.logged.add(msg)
      this.log(`tcp/fips: dropped ${typeof what === "number" ? "connection " + what : what}: ${msg}`)
    }
  }

    #backlogged(c) {
    const queued = typeof c.stream.buffered === "function" ? c.stream.buffered() : 0
    if (queued <= MAX_QUEUED_IN) return false
    this.stats.backpressured++
    return true
  }

  async #drop(c, abort) {
    c.stream.close()
    this.conns.delete(c.id)
    if (abort) await this.tcp.abort(c.id)
  }
}
