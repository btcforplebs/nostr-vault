// One read for the public post page that doesn't wait on the slowest relay. pool.querySync waited for every relay's
// EOSE or the full timeout, and a relay that never answers (damus refuses this server's address) held each of the
// page's two rounds of reads for the whole 3.5 s: a cold link took 7.2 s before a byte was sent.
// Here each relay is asked on its own, and the read ends at the first of:
// - `first(event)` is true for an event (the post itself: one copy is enough);
// - every relay has sent its EOSE;
// - more than half have, plus `graceMs` for the rest to catch up;
// - `maxWait`.
// `subscribe(url, filter, { onevent, oneose, onclose })` -> { close() } is the pool's, injectable for tests.

export const GRACE_MS = 250

export function relayRead(subscribe, relays, filter, { maxWait = 3500, first = null, graceMs = GRACE_MS } = {}) {
  const urls = [...new Set(relays)]
  return new Promise(resolve => {
    const events = [], subs = []
    let done = false, answered = 0, grace = null
    const finish = () => {
      if (done) return
      done = true
      clearTimeout(timer); clearTimeout(grace)
      for (const s of subs) { try { s.close() } catch {} }
      resolve(events)
    }
    const timer = setTimeout(finish, maxWait)
    const answer = () => {
      if (done) return
      answered++
      if (answered >= urls.length) return finish()
      if (answered * 2 > urls.length && !grace) grace = setTimeout(finish, graceMs)
    }
    if (!urls.length) return finish()
    for (const url of urls) {
      let ended = false
      const end = () => { if (!ended) { ended = true; answer() } }
      try {
        subs.push(subscribe(url, filter, {
          onevent: ev => { if (done) return; events.push(ev); if (first?.(ev)) finish() },
          oneose: end,
          onclose: end, // a relay that refuses or drops counts as answered with nothing
        }))
      } catch { end() }
    }
  })
}
