// NIP-01 over TCP/FIPS on one FSP service port. Only owner identities get past the datagram gate,
// so a stranger's SYN is dropped before the TCP stack sees it (no SYN-ACK, no RST).
import { FipsTcpEndpoint } from "@fips/tcp"
import { Nip01Session } from "./nip01.js"
import { isOwner } from "./owners.js"

export const RELAY_SERVICE_PORT = 7447
const POLL_MS = 50
const READ_CHUNK = 64 * 1024
const MAX_PENDING_OUT = 4 * 1024 * 1024

/** Wrap a FIPS datagram endpoint so service handlers only ever see datagrams from owners. */
export function ownerGatedEndpoint(endpoint, getOwners, onReject = () => {}) {
  return {
    registerService(port, handler) {
      return endpoint.registerService(port, ctx => {
        if (!isOwner(getOwners(), ctx.src)) return onReject(ctx)
        return handler(ctx)
      })
    },
    sendDatagram: args => endpoint.sendDatagram(args),
  }
}

export class TcpFipsRelayServer {
  /**
   * @param endpoint  FipsNode (or any FipsDatagramEndpoint)
   * @param store     see Nip01Session
   * @param getOwners () => Set<x-only hex>
   * clock must be Date.now-based: FipsTcpEndpoint stamps inbound segments with Date.now() itself.
   */
  constructor(endpoint, store, getOwners, { port = RELAY_SERVICE_PORT, clock = () => Date.now(), tcpConfig } = {}) {
    this.stats = { rejectedDatagrams: 0, accepted: 0, open: 0, lastReqAt: 0 }
    this.clock = clock
    this.store = store
    this.conns = new Map()
    const gated = ownerGatedEndpoint(endpoint, getOwners, () => this.stats.rejectedDatagrams++)
    this.tcp = new FipsTcpEndpoint(gated, port, tcpConfig)
    this.timer = undefined
    this.busy = false
  }

  start(intervalMs = POLL_MS) {
    this.timer ??= setInterval(() => this.tick(), intervalMs)
  }

  async stop() {
    clearInterval(this.timer)
    this.timer = undefined
    for (const c of this.conns.values()) c.session.close()
    this.conns.clear()
    await this.tcp.dispose()
  }

  /** Forward an event the page stored (generator, another session) to live subscriptions. */
  notify(ev) {
    for (const c of this.conns.values()) c.session.notify(ev)
  }

  /** One pump: timers, new connections, reads, writes, teardown. Safe to call directly in tests. */
  async tick() {
    if (this.busy) return
    this.busy = true
    try {
      const now = this.clock()
      await this.tcp.poll(now)
      for (let id; (id = await this.tcp.accept()) !== undefined; ) this.#add(id)
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

  #add(id) {
    const c = { id, out: [], outBytes: 0, enc: new TextEncoder(), session: undefined }
    c.session = new Nip01Session(
      this.#trackedStore(),
      line => {
        const b = c.enc.encode(line)
        c.out.push(b)
        c.outBytes += b.length
      },
      () => (c.fatal = true),
    )
    this.conns.set(id, c)
    this.stats.accepted++
  }

  #trackedStore() {
    const s = this.store
    return {
      event: async ev => {
        const r = await s.event(ev)
        if (r.ok) this.notify(ev)
        return r
      },
      query: f => ((this.stats.lastReqAt = this.clock()), s.query(f)),
      count: f => s.count(f),
    }
  }

  async #pump(c, now) {
    // The stack forgets a connection once its close completes; reading it after that throws.
    if ((await this.tcp.state(c.id)) === undefined) return this.#drop(c, false)
    for (let chunk; (chunk = await this.tcp.read(c.id, READ_CHUNK, now)).length; ) await c.session.onBytes(chunk)
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
    if (c.fatal || c.outBytes > MAX_PENDING_OUT) return this.#drop(c, true)
    if (state === undefined) return this.#drop(c, false)
    if (!c.out.length && (await this.tcp.isReadClosed(c.id)) && !c.closing) {
      c.closing = true
      await this.tcp.close(c.id, now)
    }
  }

  async #drop(c, abort) {
    c.session.close()
    this.conns.delete(c.id)
    if (abort) await this.tcp.abort(c.id)
  }
}
