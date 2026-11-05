// The Polls feed (NIP-88 kind 1068; parity #18), as the iPhone's (Views/PollsFeedViews.swift, PollStatusFilter):
// Following or Global (your web of trust), then Open / Closed / All, which only re-filters what is loaded. Following
// reads Haven /feed first (polls are a feed kind, the Following sync keeps them) and the network into /feed; Global is
// strangers' polls from people your web of trust vouches for, held in memory only. No JSX, so tests can import it.
import { pool, uniq } from "../net/pool.js"
import { POLL_KIND, parsePoll, isClosed } from "../components/polls.js"
import { globalTrust, trustedFilters } from "./trust.js"

export const POLL_SCOPES = [{ id: "following", label: "Following" }, { id: "global", label: "Global" }]
/** PollStatusFilter, in the iPhone's order and words. */
export const POLL_STATUSES = [{ id: "all", label: "All" }, { id: "open", label: "Open" }, { id: "closed", label: "Closed" }]
export const PAGE = 50
const KEY = "nv-polls-scope"
export const loadPollScope = (storage = globalThis.localStorage) => (storage?.getItem(KEY) === "global" ? "global" : "following")
export const savePollScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s === "global" ? "global" : "following")

/** PollStatusFilter.admits. */
export function statusAdmits(ev, status, now = Date.now() / 1000) {
  if (status === "all") return true
  const poll = parsePoll(ev)
  if (!poll) return false
  return status === "closed" ? isClosed(poll, now) : !isClosed(poll, now)
}
/** The empty line for a status (PollsFeedViews' empty states). */
export const emptyText = status => (status === "open" ? "No open polls" : status === "closed" ? "No closed polls" : "No polls yet")

/** Only polls that were asked for, each once, newest first. */
export function keepPolls(evs, authors = null) {
  const seen = new Set()
  return evs.filter(ev => ev?.id && ev.kind === POLL_KIND && (!authors || authors.has(ev.pubkey)) && !seen.has(ev.id) && seen.add(ev.id) && parsePoll(ev))
    .sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1))
}

/** One page of polls. -> { polls, fromNetwork, noWeb }. `query`, `online` and `trustOf` are for tests. */
export async function fetchPolls({ scope, me, follows, relays, vault, until, limit = PAGE, online = globalThis.navigator?.onLine !== false,
  query = (r, f, o) => pool.querySync(r, f, o), trustOf }) {
  const page = { kinds: [POLL_KIND], limit, ...(until ? { until } : {}) }
  if (scope === "global") {
    if (!online) return { polls: [], fromNetwork: false }
    const trust = await globalTrust(me, follows, trustOf)
    if (!trust) return { polls: [], fromNetwork: false, noWeb: true }
    const net = (await Promise.all(trustedFilters(page, trust).map(f => query(uniq(relays), f, { maxWait: 8000 })))).flat()
    return { polls: keepPolls(net, trust).slice(0, limit), fromNetwork: true }
  }
  if (!follows.length) return { polls: [], fromNetwork: false }
  const authors = new Set(follows)
  const local = vault ? await vault.feed.query({ ...page, authors: follows }).catch(() => []) : []
  if (!online) return { polls: keepPolls(local, authors).slice(0, limit), fromNetwork: false }
  const net = []
  for (let i = 0; i < follows.length; i += 250) net.push(...await query(uniq(relays), { ...page, authors: follows.slice(i, i + 250) }, { maxWait: 8000 }))
  const kept = keepPolls(net, authors)
  if (vault) for (const ev of kept) await vault.feed.event(ev).catch(() => {})
  return { polls: keepPolls([...local, ...kept], authors).slice(0, limit), fromNetwork: true }
}
