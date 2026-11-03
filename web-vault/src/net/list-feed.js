// People lists (NIP-51 follow sets, kind 30000) as feeds, for the desktop rail's favourites (desktop/rail): the
// user's own lists to pick from, and a list's people read once it is opened (net/feeds.js "list" choice). Only the
// public `p` tags are read; nothing is published here.
import { pool, uniq, DEFAULT_RELAYS } from "./pool.js"

export const LIST_KIND = 30000
const HEX = /^[0-9a-f]{64}$/

const dOf = ev => (ev.tags ?? []).find(t => t[0] === "d")?.[1] ?? ""
/** A list's name: its title tag, else its `d`. */
export const listName = ev => ((ev.tags ?? []).find(t => t[0] === "title" || t[0] === "name")?.[1] || dOf(ev)).trim()
/** A list's people: its public `p` tags, once each. */
export const listPeople = ev => uniq((ev.tags ?? []).filter(t => t[0] === "p" && HEX.test(t[1] ?? "")).map(t => t[1]))

/** Each list once (the newest per author and `d`), lists marked deleted (no people, or a `deleted` tag) left out. */
export function newestLists(events) {
  const by = new Map()
  for (const ev of events) {
    if (ev?.kind !== LIST_KIND || !dOf(ev)) continue
    const k = `${ev.pubkey}:${dOf(ev)}`, had = by.get(k)
    if (!had || ev.created_at > had.created_at) by.set(k, ev)
  }
  return [...by.values()].filter(ev => listPeople(ev).length && !(ev.tags ?? []).some(t => t[0] === "deleted"))
}

const read = (ctx, filter, query) => {
  const relays = uniq([...(ctx.account?.relays?.read ?? []), ...(ctx.account?.relays?.write ?? []), ...DEFAULT_RELAYS])
  return Promise.all([
    ctx.vault?.outbox?.query(filter).catch(() => []) ?? [],
    ctx.vault?.lists?.query?.(filter).catch(() => []) ?? [],
    query(relays, filter, { maxWait: 6000 }).catch(() => []),
  ]).then(a => a.flat())
}

/** The signed-in user's people lists -> [{ pubkey, d, name, people }], by name. `query` is for tests. */
export async function myLists(ctx, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await read(ctx, { kinds: [LIST_KIND], authors: [ctx.session.pubkey], limit: 100 }, query)
  return newestLists(evs).map(ev => ({ pubkey: ev.pubkey, d: dOf(ev), name: listName(ev), people: listPeople(ev).length }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

/** A "list" choice with its people and name filled in from the list's newest copy; `authors` [] when none came back. */
export async function resolveList(ctx, choice, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const j = choice.list.indexOf(":")
  const pubkey = choice.list.slice(0, j), d = choice.list.slice(j + 1)
  const [ev] = newestLists(await read(ctx, { kinds: [LIST_KIND], authors: [pubkey], "#d": [d], limit: 5 }, query))
  return { ...choice, authors: ev ? listPeople(ev) : [], label: ev ? listName(ev) : d }
}
