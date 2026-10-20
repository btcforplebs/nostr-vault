// The Recipes feed (the iPhone's RecipeFeedService): kind 30023 tagged zapcooking or nostrcooking, from zap.cooking's
// feed relay plus the read relays. Following asks for follows' recipes, Global for those of your web of trust. Recipe authors are mostly
// strangers, so nothing here is written to Haven: results live in memory only.
import { pool, uniq } from "../net/pool.js"
import { LONG_FORM_KIND, RECIPE_TOPICS, dedupeAddressable, longFormMeta } from "./longform.js"
import { globalTrust, trustedFilters } from "./trust.js"

/** zap.cooking's own feed relay: curated recipe posts, read-only (RecipeFeedService.zapCookingRelay). */
export const ZAP_COOKING_RELAY = "wss://feed.zap.cooking"
export const RECIPE_SCOPES = [{ id: "following", label: "Following" }, { id: "global", label: "Global" }]
const KEY = "nv-recipes-scope"
const CATEGORY_PREFIX = "zapcooking-"
/** How many category chips the bar shows: a 200-recipe page carries close to 300 distinct tags. */
export const MAX_CATEGORIES = 12

export function loadScope(storage = globalThis.localStorage) {
  const s = storage?.getItem(KEY)
  return RECIPE_SCOPES.some(x => x.id === s) ? s : "following"
}
export const saveScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s)

const key = url => url.toLowerCase().replace(/\/+$/, "")
/** zap.cooking's relay first, then the read relays without it. */
export const recipeRelays = readRelays => [ZAP_COOKING_RELAY, ...uniq(readRelays).filter(u => key(u) !== key(ZAP_COOKING_RELAY))]

/** The filter, or null for Following with no follows (an `authors: []` REQ matches nothing). */
export function recipeFilter(scope, follows) {
  const f = { kinds: [LONG_FORM_KIND], "#t": RECIPE_TOPICS, limit: 200 }
  if (scope !== "following") return f
  return follows.length ? { ...f, authors: follows } : null
}

/** A machine-made test post: a unix timestamp in the title, or under 30 words (the shortest real recipe was 39). */
export function looksLikeTestPost(tags, content) {
  const title = tags?.find(t => t.length >= 2 && t[0] === "title")?.[1] ?? ""
  if (/\b1[6-9][0-9]{8}\b/.test(title)) return true
  return String(content ?? "").split(/\s+/).filter(Boolean).length < 30
}

const recipeTagged = ev => ev.tags?.some(t => t.length >= 2 && t[0] === "t" && RECIPE_TOPICS.includes(String(t[1]).toLowerCase()))

/** Recipes from what the relays sent: only 30023 actually tagged as a recipe, by the authors asked for, no test posts,
 *  one per address, newest first. */
export function keepRecipes(evs, filter, trust = null) {
  const authors = trust ?? (filter.authors && new Set(filter.authors))
  return dedupeAddressable(evs.filter(ev => ev?.id && ev.kind === LONG_FORM_KIND && recipeTagged(ev)
    && (!authors || authors.has(ev.pubkey)) && !looksLikeTestPost(ev.tags, ev.content)))
}

/** The categories in these recipes (`zapcooking-dessert` -> "dessert"), most used first, ties alphabetical,
 *  counted once per recipe. */
export function recipeCategories(recipes, max = MAX_CATEGORIES) {
  const counts = new Map()
  for (const r of recipes) {
    const seen = new Set()
    for (const t of longFormMeta(r).topics) {
      if (!t.startsWith(CATEGORY_PREFIX)) continue
      const name = t.slice(CATEGORY_PREFIX.length)
      if (!name || seen.has(name)) continue
      seen.add(name)
      counts.set(name, (counts.get(name) ?? 0) + 1)
    }
  }
  return [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)).slice(0, max).map(([n]) => n)
}

export const inCategory = (recipes, category) => (category ? recipes.filter(r => longFormMeta(r).topics.includes(CATEGORY_PREFIX + category)) : recipes)

/** One load. Global keeps recipes from people your web of trust vouches for (RecipeFeedService's trust), and fails
 *  closed with no follows. `query` and `trustOf` are for tests. -> { recipes, noWeb }, or null when there was nothing
 *  to ask. */
export async function fetchRecipes({ scope, me, follows, readRelays, query = (r, f, o) => pool.querySync(r, f, o), trustOf }) {
  const filter = recipeFilter(scope, follows)
  if (!filter) return null
  if (scope === "following") return { recipes: keepRecipes(await query(recipeRelays(readRelays), filter, { maxWait: 12000 }), filter), noWeb: false }
  const trust = await globalTrust(me, follows, trustOf)
  if (!trust) return { recipes: [], noWeb: true }
  const evs = (await Promise.all(trustedFilters(filter, trust).map(f => query(recipeRelays(readRelays), f, { maxWait: 12000 })))).flat()
  return { recipes: keepRecipes(evs, filter, trust), noWeb: false }
}
