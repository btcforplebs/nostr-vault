// The Articles feed: kind 30023 from the people you follow (Following) or from your read relays (Global), as the
// iPhone's Articles mode (FeedService articlesFeedMode; SubscriptionReconciliation asks for [30023], authors: follows
// on Following). Follows' articles go into Haven /feed like their notes, so Following reads offline. Global articles
// are strangers': held in memory only, never written to /feed.
import { pool, uniq } from "../net/pool.js"
import { LONG_FORM_KIND, dedupeAddressable, isRecipe } from "./longform.js"

export const ARTICLE_SCOPES = [{ id: "following", label: "Following" }, { id: "global", label: "Global" }]
const KEY = "nv-articles-scope"
export const PAGE = 50

export function loadScope(storage = globalThis.localStorage) {
  const s = storage?.getItem(KEY)
  return ARTICLE_SCOPES.some(x => x.id === s) ? s : "following"
}
export const saveScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s)

/** The relay filter for one page, or null when there is nothing to ask (Following with no follows). */
export function articleFilter(scope, follows, { limit = PAGE, until } = {}) {
  const page = { kinds: [LONG_FORM_KIND], limit, ...(until ? { until } : {}) }
  if (scope === "following") return follows.length ? { ...page, authors: follows } : null
  return page
}

/** Articles, not recipes (those have their own feed), one per address, newest first. Only what was asked for: a
 *  relay may answer with other kinds, or with authors outside the filter. */
export function keepArticles(evs, filter) {
  const authors = filter.authors && new Set(filter.authors)
  return dedupeAddressable(evs.filter(ev => ev?.id && ev.kind === LONG_FORM_KIND && (!authors || authors.has(ev.pubkey)) && !isRecipe(ev.tags)))
}

/** One page of articles. Following: Haven /feed first, then the network into /feed; Global: the network only, in
 *  memory. `query` and `online` are for tests. -> { articles, fromNetwork } */
export async function fetchArticles({ scope, follows, relays, vault, until, limit = PAGE, online = globalThis.navigator?.onLine !== false,
  query = (r, f, o) => pool.querySync(r, f, o) }) {
  const filter = articleFilter(scope, follows, { limit, until })
  if (!filter) return { articles: [], fromNetwork: false }
  const local = scope === "following" && vault ? await vault.feed.query(filter) : []
  if (!online) return { articles: keepArticles(local, filter), fromNetwork: false }
  let net = []
  for (const f of scope === "following" ? split(filter) : [filter]) net.push(...await query(uniq(relays), f, { maxWait: 8000 }))
  net = keepArticles(net, filter)
  if (scope === "following" && vault) for (const ev of net) await vault.feed.event(ev).catch(() => {})
  return { articles: keepArticles([...local, ...net], filter).slice(0, limit), fromNetwork: true }
}

// Relays cap a filter's authors list; the Following sync asks 250 at a time, so this does too.
const split = f => {
  const out = []
  for (let i = 0; i < f.authors.length; i += 250) out.push({ ...f, authors: f.authors.slice(i, i + 250) })
  return out
}
