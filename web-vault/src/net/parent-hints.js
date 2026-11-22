// Where a reply's ancestors may live besides the user's own relays: the relay hint in each ancestor's `e` tag and
// the write relays of each ancestor's author (the tag's fifth slot, else the reply's `p` target), as Android
// (FeedServiceNoteFetching.kt) and the iPhone (ParentLookupRelays.swift) ask. A parent that lives only on its
// author's relay (a Mostr reply's parent on relay.ditto.pub) never loaded before.
import { pool } from "./pool.js"
import { followOutboxes } from "./relay-suggestions.js"
import { replyToPubkey } from "./thread.js"

const HEX64 = /^[0-9a-f]{64}$/
export const OUTBOX_PER_AUTHOR = 3
export const MAX_EXTRA = 8

const key = url => String(url).trim().toLowerCase().replace(/\/+$/, "")

/** The `e` hints and ancestor authors the `events` give for `ids`. -> { hints: [url], authors: [pubkey] } */
export function parentRefs(events, ids) {
  const want = new Set(ids), hints = [], authors = []
  for (const ev of events) {
    let named = false
    for (const t of ev?.tags ?? []) {
      if (t[0] !== "e" || !want.has(t[1]) || t[3] === "mention") continue
      if (/^wss?:\/\//.test(t[2] ?? "")) hints.push(t[2])
      if (HEX64.test(t[4] ?? "")) { authors.push(t[4]); named = true }
    }
    const p = !named && (ev?.tags ?? []).some(t => t[0] === "e" && want.has(t[1])) ? replyToPubkey(ev) : null
    if (p) authors.push(p)
  }
  return { hints: [...new Set(hints)], authors: [...new Set(authors)] }
}

/** The relays to add for `ids` beyond `known`: hints first, then up to 3 write relays per author, MAX_EXTRA in all. */
export function extraRelays({ hints, authors }, outbox, known = []) {
  const seen = new Set(known.map(key)), out = []
  const add = url => { if (out.length < MAX_EXTRA && /^wss?:\/\//.test(url ?? "") && !seen.has(key(url))) { seen.add(key(url)); out.push(url) } }
  hints.forEach(add)
  for (const pk of authors) (outbox.get(pk) ?? []).slice(0, OUTBOX_PER_AUTHOR).forEach(add)
  return out
}

/** Ask the hinted and author relays for `ids` the user's relays didn't have. Read-only: nothing is signed.
 *  -> Map id -> event (those found; each checked by the pool). */
export async function fetchFromParentRelays({ vault, events, ids, relays, outboxes = followOutboxes, query = (r, f, o) => pool.querySync(r, f, o) }) {
  const found = new Map()
  if (!ids.length) return found
  const refs = parentRefs(events, ids)
  if (!refs.hints.length && !refs.authors.length) return found
  const outbox = refs.authors.length ? await outboxes({ vault, follows: refs.authors, relays, query }).catch(() => new Map()) : new Map()
  const urls = extraRelays(refs, outbox, relays)
  if (!urls.length) return found
  const want = new Set(ids)
  for (const ev of await query(urls, { ids }, { maxWait: 6000 }).catch(() => [])) if (want.has(ev?.id)) found.set(ev.id, ev)
  return found
}
