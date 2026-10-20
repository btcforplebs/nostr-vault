// The Recipes reader: relays, filter, the test-post rule, categories, and that nothing is stored.
import test from "node:test"
import assert from "node:assert/strict"
import { ZAP_COOKING_RELAY, recipeRelays, recipeFilter, looksLikeTestPost, keepRecipes, recipeCategories, inCategory, fetchRecipes, loadScope, saveScope, MAX_CATEGORIES } from "../src/readers/recipes.js"

const A = "a".repeat(64), C = "c".repeat(64)
const words = n => Array(n).fill("stir").join(" ")
let n = 0
const recipe = (o = {}) => ({ id: (o.id ?? String(++n)).padStart(64, "0"), kind: o.kind ?? 30023, pubkey: o.pubkey ?? A, created_at: o.at ?? 100,
  content: o.content ?? words(40), tags: o.tags ?? [["d", o.d ?? `r${n}`], ["t", "zapcooking"], ...(o.cats ?? []).map(c => ["t", `zapcooking-${c}`])] })

test("zap.cooking's relay is asked first, once, then the read relays", () => {
  assert.deepEqual(recipeRelays(["wss://relay.damus.io", "wss://feed.zap.cooking/", "wss://relay.damus.io"]), [ZAP_COOKING_RELAY, "wss://relay.damus.io"])
  assert.deepEqual(recipeRelays([]), [ZAP_COOKING_RELAY])
})

test("the filter: both recipe tags, 200 at a time; Following adds follows; no follows asks nothing", () => {
  assert.deepEqual(recipeFilter("global", []), { kinds: [30023], "#t": ["zapcooking", "nostrcooking"], limit: 200 })
  assert.deepEqual(recipeFilter("following", [A]).authors, [A])
  assert.equal(recipeFilter("following", []), null)
})

test("a test post is a unix timestamp in the title or under 30 words", () => {
  assert.ok(looksLikeTestPost([["title", "Soup 1712345678"]], words(50)))
  assert.ok(looksLikeTestPost([["title", "Soup"]], words(29)))
  assert.ok(!looksLikeTestPost([["title", "Soup for 4"]], words(30)))
  assert.ok(!looksLikeTestPost([["title", "Year 2024 stew"]], words(40)))
})

test("kept: tagged 30023 by the asked authors, no test posts, one per address", () => {
  const good = recipe({ d: "soup", at: 2 }), oldEdit = recipe({ d: "soup", at: 1 })
  const evs = [good, oldEdit, recipe({ pubkey: C }), recipe({ content: "too short" }), recipe({ kind: 1 }), recipe({ tags: [["d", "plain"], ["t", "food"]] })]
  assert.deepEqual(keepRecipes(evs, { authors: [A] }).map(e => e.id), [good.id])
  assert.equal(keepRecipes(evs, {}).length, 2, "Global keeps the stranger's recipe too")
})

test("categories: most used first, ties alphabetical, once per recipe, capped", () => {
  const rs = [recipe({ cats: ["soup", "soup", "beef"] }), recipe({ cats: ["soup", "dessert"] }), recipe({ cats: ["beef"] })]
  assert.deepEqual(recipeCategories(rs), ["beef", "soup", "dessert"])
  const many = Array.from({ length: 20 }, (_, i) => recipe({ cats: [`c${String(i).padStart(2, "0")}`] }))
  assert.equal(recipeCategories(many).length, MAX_CATEGORIES)
  assert.deepEqual(inCategory(rs, "dessert").length, 1)
  assert.equal(inCategory(rs, null).length, 3)
})

test("a load asks zap.cooking's relay with the filter and returns only recipes", async () => {
  const seen = []
  const { recipes } = await fetchRecipes({ scope: "following", follows: [A], readRelays: ["wss://r"], query: async (relays, f) => { seen.push({ relays, f }); return [recipe(), recipe({ content: "x" })] } })
  assert.equal(recipes.length, 1)
  assert.equal(seen[0].relays[0], ZAP_COOKING_RELAY)
  assert.equal(await fetchRecipes({ scope: "following", follows: [], readRelays: [], query: async () => { throw new Error("asked") } }), null)
})

test("Global keeps the web of trust's recipes, asking trusted authors first; no follows fails closed", async () => {
  const asked = [], mine = recipe({ pubkey: A }), theirs = recipe({ pubkey: C })
  const { recipes } = await fetchRecipes({ scope: "global", me: A, follows: ["7".repeat(64)], readRelays: [], trustOf: async () => new Set([A]),
    query: async (r, f) => { asked.push(f.authors ?? null); return [mine, theirs] } })
  assert.deepEqual(recipes.map(r => r.pubkey), [A])
  assert.deepEqual(asked, [[A], null])
  assert.deepEqual(await fetchRecipes({ scope: "global", me: A, follows: [], readRelays: [], trustOf: async () => { throw new Error("asked") }, query: async () => { throw new Error("asked") } }), { recipes: [], noWeb: true })
})

test("the module never touches Haven: a strangers' feed stays in memory", async () => {
  const src = (await import("node:fs")).readFileSync(new URL("../src/readers/recipes.js", import.meta.url), "utf8")
  assert.ok(!/vault|\.feed\.|\.outbox\./.test(src.replace(/^\s*\/\/.*$/gm, "")))
})

const mem = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
test("scope: Following unless Global was picked", () => {
  const s = mem()
  assert.equal(loadScope(s), "following")
  saveScope("global", s)
  assert.equal(loadScope(s), "global")
})
