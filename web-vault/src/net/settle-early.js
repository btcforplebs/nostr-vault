// "Nothing here yet" without waiting on the slowest relay. A new account has no messages and no vault events, so
// every relay answers with nothing, and the screen used to hold its skeleton until the last one did: ~9 s, the
// 8 s maxWait on one slow relay (Ted's web sweep 2026-11-01, item 1). A screen may call its answer settled once half
// its relays have answered, or SETTLE_GRACE_MS after the first one did; whatever the slower relays send later still
// goes in as it lands. A relay that fails (refused, dead, blocked) is not an answer, but once every relay has
// answered or failed the round is settled whatever the count.

export const SETTLE_GRACE_MS = 1500

/**
 * Watches one round of `n` relay asks. Call `answered()` when a relay answers and `failed()` when one fails;
 * `onSettled` is called once, at the first of: half the relays (rounded up) answered, `grace` ms after the first
 * answer, or every relay done. `timer`/`clear` are for tests. -> { answered, failed, settled: () => boolean }
 */
export function settleWatch(n, onSettled, { grace = SETTLE_GRACE_MS, timer = setTimeout, clear = clearTimeout } = {}) {
  const need = Math.ceil(n / 2)
  let ok = 0, done = 0, fired = false, t = null
  const fire = () => { if (fired) return; fired = true; if (t != null) clear(t); onSettled() }
  if (n <= 0) fire()
  return {
    answered() {
      ok++; done++
      if (ok === 1 && !fired) t = timer(fire, grace)
      if (ok >= need || done >= n) fire()
    },
    failed() { done++; if (done >= n) fire() },
    settled: () => fired,
  }
}
