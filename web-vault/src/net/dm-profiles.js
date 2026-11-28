// Names for the Messages list, asked in a few batches instead of one ask per decrypt round. The list's peers grow
// eight at a time as messages open, and each change asked every profile relay again (one REQ per relay per round):
// ~100 small kind-0 REQs on a cold open (perf review 2026-11-28 #6). Peers are gathered for a short quiet spell (and
// never longer than MAX_WAIT while they keep coming), then asked once; a peer is asked once per page, found or not
// (offline or a failed ask: asked again later).
import { fetchProfiles } from "./profiles.js"

export const QUIET = 400
export const MAX_WAIT = 1500

/** A batcher; the page uses one (askDmProfiles). `fetch` and timers are for tests. */
export function dmProfileAsker({ fetch = fetchProfiles, quiet = QUIET, maxWait = MAX_WAIT, set = setTimeout, clear = clearTimeout } = {}) {
  const asked = new Set()
  let pending = new Set(), timer = null, first = 0, last = null
  const flush = () => {
    clear(timer); timer = null
    const peers = [...pending]
    pending = new Set()
    if (!peers.length || !last) return
    // Offline, or an ask that failed: these peers are asked again on the list's next change.
    const forget = () => { for (const pk of peers) asked.delete(pk) }
    if (globalThis.navigator?.onLine === false) return forget()
    Promise.resolve().then(() => fetch(last.vault, peers, last.relays)).catch(forget)
  }
  return (vault, peers, relays, now = Date.now()) => {
    last = { vault, relays }
    let added = false
    for (const pk of peers) if (!asked.has(pk)) { asked.add(pk); pending.add(pk); added = true }
    if (!added) return
    if (!timer) first = now
    clear(timer)
    timer = set(flush, Math.max(0, Math.min(quiet, first + maxWait - now)))
  }
}

export const askDmProfiles = dmProfileAsker()
