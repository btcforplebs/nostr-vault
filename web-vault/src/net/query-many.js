// A one-shot ask with several filters in ONE REQ per relay (NIP-01 allows many filters in a REQ), where querySync
// sends one filter per REQ. Each REQ counts against a relay's subscription cap, so a batch of small filters goes out
// as one REQ to each relay instead of one per filter, at once instead of one after another (profile perf review
// 2026-11-27 finding 8: 14 zap groups x 5 relays was 67 REQs, sent in turn).
import { pool } from "./pool.js"

/** The events `filters` match on `relays`, each id once (pool.verifiedOnce), once every relay has sent EOSE, closed,
 *  or `maxWait` ms have passed. -> [event] */
export function queryMany(relays, filters, { maxWait = 6000, p = pool } = {}) {
  if (!relays.length || !filters.length) return Promise.resolve([])
  return new Promise(resolve => {
    const evs = []
    let done = false, sub = null
    const finish = () => { if (done) return; done = true; sub?.close("done"); resolve(evs) }
    sub = p.subscribeMap(relays.flatMap(url => filters.map(filter => ({ url, filter }))), {
      quickConnect: true, maxWait,
      onevent: ev => { if (!done) evs.push(ev) },
      oneose: finish,
      onclose: finish,
    })
    if (done) sub.close("done")
    // A relay that never answers or closes still ends the ask: nostr-tools' maxWait counts from each relay's open.
    setTimeout(finish, maxWait + 2000)?.unref?.()
  })
}
