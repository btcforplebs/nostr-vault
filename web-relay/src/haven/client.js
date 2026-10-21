// NIP-01 client over one Haven stream in "nip01" mode: NDJSON lines in and out, one route per stream.
// The page uses it for its own reads and writes, so they go through Haven's policies like any other client's.

/**
 * @param conn  a havenConn(...) handle: { write(Uint8Array), onData(cb), onClose(cb), close() }
 * @param auth  optional (challenge) => Promise<signed kind 22242 event>. When set, a REQ or COUNT Haven closes
 *              with "auth-required:" is answered with NIP-42 AUTH once and sent again.
 */
export class HavenClient {
  constructor(conn, { timeoutMs = 15_000, auth } = {}) {
    this.conn = conn
    this.timeoutMs = timeoutMs
    this.auth = auth
    this.challenge = undefined
    this.authed = undefined
    this.pending = new Map()
    this.buf = ""
    this.dec = new TextDecoder()
    this.enc = new TextEncoder()
    this.closed = false
    this.n = 0
    conn.onData(b => this.#onData(b))
    conn.onClose(() => this.#onClose())
  }

  /** -> { ok, message } */
  event(ev) {
    return this.#ask(ev.id, ["EVENT", ev])
  }

  /** filters: one filter object or an array of them -> events[] */
  query(filters) {
    return this.#authRetry(() => {
      const id = `q${++this.n}`
      return this.#ask(id, ["REQ", id, ...[filters].flat()])
    })
  }

  /** -> number. Haven's khatru answers COUNT on the routes that allow it. */
  count(filters) {
    return this.#authRetry(() => {
      const id = `c${++this.n}`
      return this.#ask(id, ["COUNT", id, ...[filters].flat()])
    })
  }

  async #authRetry(send) {
    try {
      return await send()
    } catch (e) {
      if (!this.auth || !String(e.message).startsWith("auth-required")) throw e
      await this.#authenticate()
      return send()
    }
  }

  // One AUTH per challenge, shared by every request that hit auth-required at the same time.
  #authenticate() {
    if (this.authed?.challenge === this.challenge) return this.authed.done
    const challenge = this.challenge
    const done = (async () => {
      if (!challenge) throw new Error("auth-required, but Haven sent no AUTH challenge")
      const ev = await this.auth(challenge)
      const r = await this.#ask(ev.id, ["AUTH", ev])
      if (!r.ok) throw new Error(`haven refused AUTH: ${r.message}`)
    })()
    this.authed = { challenge, done }
    done.catch(() => { if (this.authed?.done === done) this.authed = undefined })
    return done
  }

  close() {
    this.conn.close()
    this.#onClose()
  }

  #ask(key, msg) {
    if (this.closed) return Promise.reject(new Error("haven stream closed"))
    if (this.pending.has(key)) return Promise.reject(new Error(`request ${key} already in flight`))
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.#settle(key, new Error(`haven: no answer to ${msg[0]} in ${this.timeoutMs} ms`)), this.timeoutMs)
      this.pending.set(key, { resolve, reject, timer, events: [] })
      this.conn.write(this.enc.encode(JSON.stringify(msg) + "\n"))
    })
  }

  #settle(key, err, value) {
    const p = this.pending.get(key)
    if (!p) return
    this.pending.delete(key)
    clearTimeout(p.timer)
    err ? p.reject(err) : p.resolve(value)
  }

  #onData(bytes) {
    this.buf += this.dec.decode(bytes, { stream: true })
    let i
    while ((i = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, i)
      this.buf = this.buf.slice(i + 1)
      if (line) this.#onLine(line)
    }
  }

  #onLine(line) {
    let m
    try {
      m = JSON.parse(line)
    } catch {
      return
    }
    if (!Array.isArray(m)) return
    const p = this.pending.get(m[1])
    switch (m[0]) {
      case "AUTH":
        this.challenge = m[1]
        return
      case "OK":
        return this.#settle(m[1], undefined, { ok: !!m[2], message: m[3] ?? "" })
      case "EVENT":
        return p?.events.push(m[2])
      case "EOSE":
        // One-shot reads: close the subscription so Haven doesn't keep it live.
        this.conn.write(this.enc.encode(JSON.stringify(["CLOSE", m[1]]) + "\n"))
        return this.#settle(m[1], undefined, p?.events ?? [])
      case "CLOSED":
        return this.#settle(m[1], new Error(m[2] || "subscription closed by relay"))
      case "COUNT":
        return this.#settle(m[1], undefined, m[2]?.count ?? 0)
    }
  }

  #onClose() {
    if (this.closed) return
    this.closed = true
    for (const key of [...this.pending.keys()]) this.#settle(key, new Error("haven stream closed"))
  }
}
