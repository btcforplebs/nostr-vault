// Stand-in for the wasm Haven's JS entry point, honouring the same contract:
//   havenStart(cfg) / havenConn(id, {mode:"nip01", route}) -> {write, onData, onClose, close} / havenStop()
// Behind it: one NIP-01 session per stream, a shared in-memory store, nostr-tools signature checks, and the
// outbox write rule (owner or whitelist only). Only route "/" exists. It is a test double, not Haven.
import { verifyEvent } from "nostr-tools/pure"
import { matchFilters } from "nostr-tools/filter"
import { Nip01Session } from "./nip01-session.js"
import { xOnly } from "../../src/fips/owners.js"

export function havenStub() {
  let cfg, writers
  const evs = new Map()
  const live = new Set()
  const store = {
    event: async ev => {
      if (!verifyEvent(ev)) return { ok: false, message: "invalid: bad signature or id" }
      if (!writers.has(ev.pubkey)) return { ok: false, message: "restricted: you must be whitelisted to post to this relay" }
      evs.set(ev.id, ev)
      for (const s of live) s.notify(ev)
      return { ok: true }
    },
    query: async fs => [...evs.values()].filter(e => matchFilters(fs, e)),
    count: async fs => [...evs.values()].filter(e => matchFilters(fs, e)).length,
  }
  const api = {
    evs,
    conns: [],
    havenStart: async c => {
      if (!xOnly(c?.ownerNpub)) throw new Error("ownerNpub required")
      cfg = c
      writers = new Set([c.ownerNpub, ...(c.whitelist ?? [])].map(xOnly))
      evs.clear()
    },
    // stall: while true, written bytes queue in buffered() instead of reaching the session.
    stall: false,
    havenConn: (id, opts = {}) => {
      const mode = opts.mode ?? "nip01", route = opts.route ?? "/"
      // Like Haven's refuse(): a working, already-closed stream with `error`, never a throw.
      const why = !cfg ? "havenConn: relay is not running"
        : mode !== "nip01" || route !== "/" ? `stub supports nip01 on / only, got ${mode} ${route}`
        : undefined
      let onData = () => {}, onClose = () => {}, closed = false, chain = Promise.resolve(), queued = []
      const enc = new TextEncoder()
      const session = why ? undefined : new Nip01Session(store, line => queueMicrotask(() => !closed && onData(enc.encode(line))), () => conn.close())
      if (session) live.add(session)
      // Serialise: Nip01Session.onBytes is async and keeps a partial-line buffer.
      const drain = () => { if (api.stall) return; for (const b of queued.splice(0)) chain = chain.then(() => session.onBytes(b)) }
      const conn = {
        write: b => { if (!closed) { queued.push(b.slice()); drain() } },
        buffered: () => { drain(); return queued.reduce((n, b) => n + b.length, 0) },
        onData: cb => (onData = cb),
        onClose: cb => { onClose = cb; if (why) queueMicrotask(() => onClose(why)) },
        close: () => {
          if (closed) return
          closed = true
          session?.close()
          live.delete(session)
          queueMicrotask(() => onClose("closed"))
        },
      }
      if (why) { closed = true; conn.error = why }
      api.conns.push({ id, opts, conn })
      return conn
    },
    havenStop: async () => {
      for (const s of live) s.close()
      live.clear()
      cfg = undefined
    },
  }
  return api
}
