// A small read-only relay client for the stats scan: one socket per relay, kept open and reused for every REQ in
// turn (relay.damus.io and nostr.wine refuse most connections when a new one is opened per query: measured
// 2026-11-18, 20 of 25 and 19 of 25 refused). Node's built-in WebSocket (Node 22+), no dependencies. It never signs
// or publishes anything. Call closeAll() when done, or Node keeps running.

export const USER_AGENT = "nostrvault-stats/1.0 (+https://nostrvault.app/stats/)"

// Open sockets, per WebSocket implementation (so tests with fake sockets never share one) and relay URL.
const pools = new WeakMap()
// Connect failures in a row, per relay. After GIVE_UP of them the relay is skipped for the rest of the run: a relay
// that is down costs a connect timeout on every filter otherwise (nos.lol and relay.nostr.band, 2026-11-18).
const failures = new WeakMap()
export const GIVE_UP = 3

/** The relay's open connection: { ready: Promise<boolean>, ws, subs: Map<sub, onMessage> }. Opens one if needed. */
function connection(url, WebSocketImpl) {
  let pool = pools.get(WebSocketImpl)
  if (!pool) pools.set(WebSocketImpl, (pool = new Map()))
  let fails = failures.get(WebSocketImpl)
  if (!fails) failures.set(WebSocketImpl, (fails = new Map()))
  const open = pool.get(url)
  if (open && !open.dead) return open
  if ((fails.get(url) ?? 0) >= GIVE_UP) return { subs: new Map(), dead: true, gaveUp: true, ready: Promise.resolve(false), die() {} }
  const conn = { subs: new Map(), dead: false, ws: null, opened: false }
  const die = () => {
    if (conn.dead) return
    conn.dead = true
    if (pool.get(url) === conn) pool.delete(url)
    for (const onMessage of conn.subs.values()) onMessage(null)
    conn.subs.clear()
    try { conn.ws?.close() } catch {}
  }
  conn.die = die
  conn.ready = new Promise(resolve => {
    try {
      // A User-Agent: relay.damus.io's front end drops Node's default WebSocket handshake (measured 2026-11-18).
      conn.ws = new WebSocketImpl(url, { headers: { "user-agent": USER_AGENT } })
    } catch {
      die()
      return resolve(false)
    }
    conn.ws.onopen = () => { conn.opened = true; fails.set(url, 0); resolve(true) }
    const lost = () => { if (!conn.opened && !conn.dead) fails.set(url, (fails.get(url) ?? 0) + 1); die(); resolve(false) }
    conn.ws.onerror = lost
    conn.ws.onclose = lost
    conn.ws.onmessage = msg => {
      let data
      try { data = JSON.parse(typeof msg.data === "string" ? msg.data : String(msg.data)) } catch { return }
      if (Array.isArray(data)) conn.subs.get(data[1])?.(data)
    }
  })
  pool.set(url, conn)
  return conn
}

/** Closes every open socket (for one WebSocket implementation, the real one by default). */
export function closeAll(WebSocketImpl = globalThis.WebSocket) {
  failures.get(WebSocketImpl)?.clear()
  const pool = pools.get(WebSocketImpl)
  if (!pool) return
  for (const conn of pool.values()) { conn.dead = true; try { conn.ws?.close() } catch {} }
  pool.clear()
}

/**
 * Runs one filter on one relay. Resolves { events, ok } where ok means the relay sent EOSE; a timeout, a CLOSED or
 * a dropped socket resolves with ok false and whatever arrived, so one slow relay never stops the scan. A timeout
 * drops the socket too, and the next query opens a fresh one.
 */
export function query(url, filter, { timeoutMs = 20000, WebSocketImpl = globalThis.WebSocket } = {}) {
  return new Promise(resolve => {
    const events = []
    const sub = "s" + Math.random().toString(36).slice(2, 10)
    const conn = connection(url, WebSocketImpl)
    let done = false
    const finish = (ok, { drop = false, why = null } = {}) => {
      if (done) return
      done = true
      clearTimeout(timer)
      conn.subs.delete(sub)
      if (drop) conn.die()
      else if (!conn.dead) try { conn.ws.send(JSON.stringify(["CLOSE", sub])) } catch {}
      resolve({ events, ok, why })
    }
    const timer = setTimeout(() => finish(false, { drop: true, why: "timeout" }), timeoutMs)
    conn.subs.set(sub, data => {
      if (data === null) return finish(false, { why: conn.opened ? "socket closed" : "could not connect" })
      if (data[0] === "EVENT" && data[2] && typeof data[2] === "object") events.push(data[2])
      else if (data[0] === "EOSE") finish(true)
      else if (data[0] === "CLOSED") finish(false, { why: `CLOSED ${String(data[2] ?? "").slice(0, 80)}` })
    })
    conn.ready.then(open => {
      if (done) return
      if (!open) return finish(false, { why: conn.gaveUp ? "skipped: could not connect 3 times" : "could not connect" })
      try { conn.ws.send(JSON.stringify(["REQ", sub, filter])) } catch { finish(false, { drop: true, why: "send failed" }) }
    })
  })
}

/**
 * Pages one filter back in time on one relay (`until` = oldest seen - 1) until a page comes back empty or
 * `maxPages` is reached. ok is true when every page ended in EOSE; capped is true when it stopped at `maxPages`
 * with more left to read.
 */
export async function queryPaged(url, filter, { pageSize = 500, maxPages = 40, retry = true, ...opts } = {}) {
  const all = []
  let until = filter.until
  let ok = true
  let capped = false
  let why = null
  for (let i = 0; ; i++) {
    if (i === maxPages) { capped = true; break }
    const pageFilter = { ...filter, limit: pageSize, ...(until ? { until } : {}) }
    let page = await query(url, pageFilter, opts)
    // A dropped socket or a timeout mid-scan: ask once more on a fresh socket, so the rest of this relay's notes
    // for the filter aren't lost (measured 2026-11-18: 2-4 of 49 filters per relay hit this in a full scan).
    if (!page.ok && retry && (page.why === "socket closed" || page.why === "timeout")) {
      const again = await query(url, pageFilter, opts)
      if (again.ok || again.events.length >= page.events.length) page = again
    }
    ok = ok && page.ok
    why = why ?? page.why
    if (!page.events.length) break
    all.push(...page.events)
    const oldest = Math.min(...page.events.map(e => e.created_at))
    if (filter.since && oldest <= filter.since) break
    if (until !== undefined && oldest >= until) break // the relay ignored `until`: stop rather than loop
    until = oldest - 1
  }
  return { events: all, ok, capped, why }
}

/** The filter on every relay at once. Returns every event (duplicates included), the relays that answered, and the relays that hit maxPages. */
export async function queryRelays(relays, filter, opts = {}) {
  const results = await Promise.all(relays.map(url => queryPaged(url, filter, opts)))
  return {
    events: results.flatMap(r => r.events),
    answered: relays.filter((_, i) => results[i].ok),
    capped: relays.filter((_, i) => results[i].capped),
    why: Object.fromEntries(relays.map((r, i) => [r, results[i].why]).filter(([, w]) => w)),
  }
}
