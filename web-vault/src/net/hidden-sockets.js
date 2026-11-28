// A hidden tab puts its relay sockets down (launch + background review 2026-11-28, finding 5: hidden 5 min, every
// socket stayed open with its 29 s ping timer). After HIDDEN_PARK_MS hidden, each relay of the pool goes quiet:
// - an idle one (nothing open on it) is closed and dropped, as the cap would drop it; the next ask opens it again.
// - one with subscriptions still open on it (a live feed, a thread, live chat) is parked: its socket and ping timer
//   are closed, but the relay stays in the pool with its subscriptions, marked as reconnecting, so nothing is told
//   it closed (watchLive would only open it again 30 s later). Coming back to the tab reconnects it through the
//   pool's gates (attemptReconnect), and nostr-tools re-sends each subscription from its last event (since).
// A signer's relay (a bunker's) is never parked: the signer answers only there.
// A one-shot ask while hidden (the notification poll, every 5 min) still works: it reconnects what it needs, and
// that relay is put down again PARK_AGAIN_MS after its last use.
export const HIDDEN_PARK_MS = 2 * 60_000
export const PARK_AGAIN_MS = 30_000

const busy = r => r.openSubs.size > 0 || r.openEventPublishes.size > 0 || r.openCountRequests.size > 0
const inFlight = r => r.openEventPublishes.size > 0 || r.openCountRequests.size > 0

/** Closes a relay's socket and ping timer but keeps it, and its subscriptions, for a reconnect later. */
export function parkRelay(r) {
  if (r.reconnectTimeoutHandle) { clearTimeout(r.reconnectTimeoutHandle); r.reconnectTimeoutHandle = undefined }
  if (r.pingIntervalHandle) { clearInterval(r.pingIntervalHandle); r.pingIntervalHandle = undefined }
  const ws = r.ws
  if (ws) { ws.onopen = null; ws.onerror = null; ws.onclose = null }
  r._connected = false
  r.connectionPromise = undefined
  // nostr-tools reads this in the next socket's onopen: re-send each open subscription from its last event, not from
  // its first `since` again. The pool's gates treat it as a reconnect too (charged in watch(), not ensureRelay).
  r.reconnectAttempts = Math.max(1, r.reconnectAttempts)
  try { if (ws && ws.readyState < 2) ws.close() } catch {}
}

/**
 * Wires `pool` (a LivePool) to the page's visibility. `pool.isHidden()` is read on every change; the page calls
 * pool.visibilityChanged() from its visibilitychange listener (pool.js). -> the controller (tests).
 */
export function hiddenSockets(pool, { setTimer = setTimeout, clearTimer = clearTimeout, now = () => Date.now() } = {}) {
  const parked = new Set() // relays put down while hidden, still in the pool
  let timer = null
  const schedule = ms => {
    if (timer) clearTimer(timer)
    timer = setTimer(() => { timer = null; pass() }, ms)
    timer?.unref?.() // node (the tests) only
  }
  const again = () => pool.parkAgainMs ?? PARK_AGAIN_MS
  const pass = () => {
    if (!pool.isHidden()) return
    let next = Infinity
    for (const [key, r] of [...pool.relays]) {
      if (pool.signerRelays.has(key) || !r.connected) continue
      const quiet = now() - (pool.lastUsed.get(r) || 0)
      if (inFlight(r) || quiet < again()) { next = Math.min(next, Math.max(10, again() - quiet)); continue }
      if (!busy(r)) {
        pool.relays.delete(key)
        pool.forgetReconnect(key)
        r.close()
        continue
      }
      if (r.ws && r.ws.readyState !== 3) pool.closing.add(r.ws) // still counts against Brave's cap until it closes
      pool.forgetReconnect(key)
      parkRelay(r)
      parked.add(r)
    }
    if (next < Infinity) schedule(next)
  }
  return {
    parked,
    /** Hidden: put the sockets down after HIDDEN_PARK_MS. Seen again: reconnect what was parked. */
    changed() {
      if (pool.isHidden()) { schedule(pool.hiddenParkMs ?? HIDDEN_PARK_MS); return }
      if (timer) { clearTimer(timer); timer = null }
      const back = [...parked]
      parked.clear()
      for (const r of back) if (!r.connected && !r.connectionPromise) pool.attemptReconnect(r)
    },
    /** A relay was opened or used while hidden: put it down again once it has been quiet for PARK_AGAIN_MS. */
    used() { if (pool.isHidden() && parked.size && !timer) schedule(again()) },
    /** Parked while hidden: a reconnect of the pool's own (retries, `online`) waits for the tab to be seen. */
    holds: r => parked.has(r) && pool.isHidden(),
    stop() { if (timer) clearTimer(timer); timer = null; parked.clear() },
  }
}
