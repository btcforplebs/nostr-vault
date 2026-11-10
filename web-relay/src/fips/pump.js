// The relay's two TCP pumps (tcp-server.js on 7447, mesh-door.js on 80) used to tick at 50 Hz and 20 Hz for the
// relay's whole life, idle or not: up to 70 wakeups a second from a tab that is mostly waiting for a peer. With no
// connection open there is nothing to read, write or accept, so the pump drops to IDLE_MS and a datagram wakes it at
// once (wake()), which is what an arriving SYN is. Idle, a tick still runs every IDLE_MS for the stack's own timers
// (retransmits, TIME_WAIT), so nothing that needs the clock waits for a datagram.

/** How often an idle pump ticks: a safety net for the stack's timers, not a poll for work. */
export const IDLE_MS = 500

/**
 * tick() every `fastMs` while busy() says a connection is open, every IDLE_MS otherwise. A tick that is already
 * running cannot take another: the request is remembered and one more tick runs when it finishes. -> { start, stop,
 * wake }. `start(ms)` changes the fast interval; `wake()` ticks at once (a datagram arrived).
 */
export function pollPump(tick, busy, initialMs) {
  let fastMs = initialMs, timer, running = false, again = false, stopped = true
  const at = ms => { timer = setTimeout(fire, ms); timer?.unref?.() } // unref: node (the tests) only
  const schedule = () => at(busy() ? fastMs : IDLE_MS)
  const fire = () => { if (!stopped) run() }
  const run = () => {
    if (running) { again = true; return }
    running = true
    Promise.resolve().then(tick).catch(() => {}).finally(() => {
      running = false
      if (stopped) return
      // After the tick, so the interval follows what it found: a connection it accepted brings the fast tick back.
      if (again) { again = false; run() } else schedule()
    })
  }
  return {
    start(ms) {
      if (!stopped) return
      if (ms) fastMs = ms
      stopped = false
      schedule()
    },
    stop() { stopped = true; again = false; clearTimeout(timer); timer = undefined },
    /** A datagram arrived: tick now rather than at the next (slow, when idle) tick. */
    wake() { if (stopped) return; clearTimeout(timer); at(0) },
  }
}
