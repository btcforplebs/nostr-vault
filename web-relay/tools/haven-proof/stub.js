// JS stand-in for Ted's wasm entry point (same havenStart/havenConn/havenStop contract), used only to
// check this harness itself. In-memory, so the phase-2 reload check is expected to fail under STUB=1.
import { Nip01Session } from "../../src/fips/nip01.js"
import { matchFilters } from "nostr-tools/filter"
import { verifyEvent } from "nostr-tools/pure"
import { decode } from "nostr-tools/nip19"

export function installStub() {
  const evs = new Map(), sessions = new Set()
  let owner
  globalThis.havenStart = async cfg => { owner = decode(cfg.ownerNpub).data }
  globalThis.havenStop = async () => { for (const s of sessions) s.close(); sessions.clear() }
  globalThis.havenConn = () => {
    let onData = () => {}, onClose = () => {}, closed = false
    const store = {
      event: async ev => {
        if (!verifyEvent({ ...ev })) return { ok: false, message: "invalid: bad signature" }
        if (ev.pubkey !== owner) return { ok: false, message: "restricted: not the owner" }
        evs.set(ev.id, ev)
        for (const s of sessions) s.notify(ev)
        return { ok: true, message: "" }
      },
      query: async fs => [...evs.values()].filter(e => matchFilters(fs, e)),
      count: async fs => [...evs.values()].filter(e => matchFilters(fs, e)).length,
    }
    const enc = new TextEncoder()
    const s = new Nip01Session(store, line => queueMicrotask(() => onData(enc.encode(line))))
    sessions.add(s)
    const close = () => { if (closed) return; closed = true; s.close(); sessions.delete(s); queueMicrotask(() => onClose()) }
    return { write: b => s.onBytes(b.slice()), onData: cb => (onData = cb), onClose: cb => (onClose = cb), close }
  }
}
