// relay.damus.io bans an address that sends it too many requests in 24 hours, and lists the banned addresses in public
// (2026-10-31). A user must never land on that list because of this app, so the pool spends a budget per host: each
// REQ, COUNT, publish and ping to a budgeted host takes one, and once a minute's or a day's share is gone that host is
// skipped until the window turns over. The query still answers from the other relays, as it does for a dead host.
// Damus doesn't publish its threshold. One open tab measured 31 requests to damus at sign-in and ~4 a minute after
// (2 for the Vault poll, 2 for nostr-tools' keep-alive ping), ~5,800 a day for a tab left open: these caps sit well
// under that. The day's count is kept in localStorage so every tab and reload on this browser shares one budget.

export const RELAY_BUDGETS = { "relay.damus.io": { perMinute: 30, perDay: 1000 } }
const KEY = "nv-relay-budget"

const hostOf = url => { try { return new URL(url).hostname.toLowerCase() } catch { return "" } }
const dayOf = ms => new Date(ms).toISOString().slice(0, 10)

/**
 * take(url) -> whether a request to `url` may go now (and counts it). Hosts without a budget always may.
 * `storage` holds { [host]: { day, n, minute, m } }; `now` is for tests.
 */
export function relayBudget({ budgets = RELAY_BUDGETS, storage = globalThis.localStorage, now = Date.now } = {}) {
  let memory = {} // when storage is missing or refuses (private mode, quota), this tab still keeps count
  const read = () => {
    try { const v = JSON.parse(storage?.getItem(KEY) ?? "null"); if (v && typeof v === "object") return v } catch {}
    return memory
  }
  const write = all => { memory = all; try { storage?.setItem(KEY, JSON.stringify(all)) } catch {} }
  return {
    take(url) {
      const host = hostOf(url), cap = budgets[host]
      if (!cap) return true
      const t = now(), day = dayOf(t), minute = Math.floor(t / 60_000)
      const all = read()
      const s = all[host] ?? {}
      const n = s.day === day ? s.n : 0, m = s.minute === minute ? s.m : 0
      if (n >= cap.perDay || m >= cap.perMinute) return false
      write({ ...all, [host]: { day, n: n + 1, minute, m: m + 1 } })
      return true
    },
    /** What is left today and this minute for `url`'s host, or null when it has no budget. */
    left(url) {
      const host = hostOf(url), cap = budgets[host]
      if (!cap) return null
      const t = now(), s = read()[host] ?? {}
      return { day: cap.perDay - (s.day === dayOf(t) ? s.n : 0), minute: cap.perMinute - (s.minute === Math.floor(t / 60_000) ? s.m : 0) }
    },
  }
}
