// NIP-01 relay session over a byte stream. Framing: NDJSON, one JSON array per line, UTF-8, "\n" terminated.
// JSON escapes newlines inside strings, so a line is always exactly one message.
import { matchFilters } from "nostr-tools/filter"

export const MAX_LINE_BYTES = 512 * 1024
export const MAX_SUBS = 20

export class Nip01Session {
  /**
   * @param store  { event(ev) -> {ok, message}, query(filters) -> events[], count(filters) -> number }
   * @param send   (line: string) => void, called with one complete NDJSON line ("...\n")
   * @param onFatal (reason) => void, protocol violation; caller resets the stream
   */
  constructor(store, send, onFatal = () => {}) {
    this.store = store
    this.send = send
    this.onFatal = onFatal
    this.subs = new Map()
    this.buf = new Uint8Array(0)
    this.dec = new TextDecoder("utf-8", { fatal: true })
    this.closed = false
  }

  /** Feed received stream bytes. */
  async onBytes(chunk) {
    if (this.closed) return
    const joined = new Uint8Array(this.buf.length + chunk.length)
    joined.set(this.buf)
    joined.set(chunk, this.buf.length)
    let start = 0
    for (let i = 0; i < joined.length; i++) {
      if (joined[i] !== 0x0a) continue
      const line = joined.subarray(start, i)
      start = i + 1
      if (line.length) await this.#onLine(line)
      if (this.closed) return
    }
    this.buf = joined.slice(start)
    if (this.buf.length > MAX_LINE_BYTES) this.#fatal("line too long")
  }

  /** A stored event that other sessions or the page inserted; forward to matching live subscriptions. */
  notify(ev) {
    for (const [id, filters] of this.subs) if (matchFilters(filters, ev)) this.#out(["EVENT", id, ev])
  }

  close() {
    this.closed = true
    this.subs.clear()
  }

  #out(msg) {
    if (!this.closed) this.send(JSON.stringify(msg) + "\n")
  }

  #fatal(reason) {
    this.#out(["NOTICE", `error: ${reason}`])
    this.close()
    this.onFatal(reason)
  }

  async #onLine(bytes) {
    if (bytes.length > MAX_LINE_BYTES) return this.#fatal("line too long")
    let msg
    try {
      msg = JSON.parse(this.dec.decode(bytes))
    } catch {
      return this.#out(["NOTICE", "error: bad JSON"])
    }
    if (!Array.isArray(msg) || typeof msg[0] !== "string") return this.#out(["NOTICE", "error: not a NIP-01 message"])
    switch (msg[0]) {
      case "EVENT": {
        const ev = msg[1]
        const r = await this.store.event(ev)
        return this.#out(["OK", ev?.id ?? "", !!r.ok, r.ok ? "" : r.message ?? "error: rejected"])
      }
      case "REQ": {
        const [, id, ...filters] = msg
        if (typeof id !== "string" || !id || id.length > 64) return this.#out(["NOTICE", "error: bad subscription id"])
        if (!filters.length || !filters.every(f => f && typeof f === "object" && !Array.isArray(f)))
          return this.#out(["CLOSED", id, "error: bad filter"])
        if (!this.subs.has(id) && this.subs.size >= MAX_SUBS) return this.#out(["CLOSED", id, "error: too many subscriptions"])
        this.subs.set(id, filters)
        const seen = new Set()
        for (const ev of await this.store.query(filters)) {
          if (seen.has(ev.id)) continue
          seen.add(ev.id)
          this.#out(["EVENT", id, ev])
        }
        return this.#out(["EOSE", id])
      }
      case "CLOSE":
        this.subs.delete(msg[1])
        return
      case "COUNT": {
        const [, id, ...filters] = msg
        return this.#out(["COUNT", id, { count: await this.store.count(filters) }])
      }
      default:
        return this.#out(["NOTICE", `error: unsupported message ${String(msg[0]).slice(0, 16)}`])
    }
  }
}
