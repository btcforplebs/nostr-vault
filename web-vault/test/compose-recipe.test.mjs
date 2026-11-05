// New Recipe (kind 30023 in zap.cooking's shape): the iPhone's LongFormDraft recipe body and tags, LongFormComposeView
// .lines, Publish's hint, the draft, the Recipe kind in New Post, and that the Recipes feed lists what it writes.
// Throwaway keys and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishKind } from "../src/net/sync.js"
import { EMPTY_RECIPE, LONG_FORM_KIND, buildRecipe, canPublishRecipe, hasRecipe, lines, recipeContent, recipeDraftOf, recipeFromDraft, recipeHint } from "../src/screens/compose/recipe.js"
import { isRecipe, longFormMeta } from "../src/readers/longform.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { COMPOSE_TYPES, composeHref, composeType } = await import("../src/screens/compose/ComposeKinds.jsx")
await import("../src/screens/ComposeScreen.jsx") // the dispatcher, with New Recipe, still loads in node
const { RecipeButton } = await import("../src/readers/RecipesScreen.jsx")

const full = { ...EMPTY_RECIPE, title: "  Shakshuka  ", summary: " Eggs in spicy tomato ", body: "Use ripe #tomatoes.",
  prepTime: " 10 min ", cookTime: "25 min", servings: "4", ingredients: "- 4 eggs\n\n• 1 can tomatoes\n* 1 onion\n",
  directions: "1. Fry the onion\n2) Add the tomatoes\nCrack in the eggs", categories: "Breakfast, vegetarian, , !!!" }

test("lines: one per non-empty line, a pasted bullet or number dropped", () => {
  assert.deepEqual(lines("- 2 eggs\n\n  * 1 cup flour  \n• salt\n1. Preheat\n12) Bake\n3 eggs"), ["2 eggs", "1 cup flour", "salt", "Preheat", "Bake", "3 eggs"])
  assert.deepEqual(lines("  \n"), [])
})

test("recipeContent: Chef's notes, Details, Ingredients, numbered Directions, as LongFormDraft.content() writes them", () => {
  assert.equal(recipeContent(full), [
    "## Chef's notes\n\nUse ripe #tomatoes.",
    "## Details\n\n- ⏲️ Prep time: 10 min\n- 🍳 Cook time: 25 min\n- 🍽️ Servings: 4",
    "## Ingredients\n\n- 4 eggs\n- 1 can tomatoes\n- 1 onion",
    "## Directions\n\n1. Fry the onion\n2. Add the tomatoes\n3. Crack in the eggs",
  ].join("\n\n"))
  // No notes, no details: those sections are left out.
  assert.equal(recipeContent({ ...EMPTY_RECIPE, ingredients: "salt", directions: "stir" }), "## Ingredients\n\n- salt\n\n## Directions\n\n1. stir")
})

test("buildRecipe: an article's tags plus zapcooking, nostrcooking, zapcooking-<category> and #hashtags, no repeats", () => {
  const { content, tags } = buildRecipe({ ...full, categories: full.categories + ", Breakfast", cover: { url: "https://cdn.example/s.jpg" } },
    { identifier: "shakshuka-abc123", publishedAt: 1762300000 })
  assert.equal(content, recipeContent(full))
  assert.deepEqual(tags, [["d", "shakshuka-abc123"], ["title", "Shakshuka"], ["summary", "Eggs in spicy tomato"], ["image", "https://cdn.example/s.jpg"],
    ["published_at", "1762300000"], ["t", "zapcooking"], ["t", "nostrcooking"], ["t", "zapcooking-breakfast"], ["t", "zapcooking-vegetarian"], ["t", "tomatoes"]])
  // What it writes is a recipe to our reader and the Recipes feed.
  assert.equal(isRecipe(tags), true)
  const meta = longFormMeta({ kind: LONG_FORM_KIND, tags })
  assert.equal(meta.title, "Shakshuka"); assert.equal(meta.summary, "Eggs in spicy tomato")
  assert.match(buildRecipe({ ...full }).tags[0][1], /^shakshuka-[0-9a-f]{6}$/)
})

test("Publish needs a title, an ingredient and a step; the hint is the iPhone's and an empty form says nothing", () => {
  assert.equal(recipeHint(EMPTY_RECIPE), null)
  assert.equal(canPublishRecipe(EMPTY_RECIPE), false)
  assert.equal(recipeHint({ ...EMPTY_RECIPE, ingredients: "salt" }), "Add a title to publish.")
  assert.equal(recipeHint({ ...EMPTY_RECIPE, title: "T" }), "Add at least one ingredient to publish.")
  assert.equal(recipeHint({ ...EMPTY_RECIPE, title: "T", ingredients: " - \n" }), "Add at least one ingredient to publish.")
  assert.equal(recipeHint({ ...EMPTY_RECIPE, title: "T", ingredients: "salt" }), "Add at least one step to publish.")
  assert.equal(canPublishRecipe({ ...EMPTY_RECIPE, title: "T", ingredients: "salt", directions: "stir" }), true)
  assert.equal(recipeHint({ ...EMPTY_RECIPE, title: "T", ingredients: "salt", directions: "stir" }), null)
})

test("the draft keeps every field and an uploaded cover, not a pending one, and opens back the same", () => {
  assert.equal(hasRecipe(EMPTY_RECIPE), false)
  assert.equal(hasRecipe({ ...EMPTY_RECIPE, servings: "2" }), true)
  const d = recipeDraftOf({ ...full, cover: { preview: "blob:x", status: "uploading" } })
  assert.equal("cover" in d, false)
  assert.deepEqual(recipeFromDraft(d), { ...full, cover: null })
  const withCover = recipeDraftOf({ ...full, cover: { preview: "blob:x", status: "done", url: "https://c/1.jpg", sha256: "ab", mime: "image/jpeg", size: 9 } })
  assert.deepEqual(withCover.cover, { url: "https://c/1.jpg", sha256: "ab", mime: "image/jpeg" })
  assert.deepEqual(recipeFromDraft(withCover).cover, { url: "https://c/1.jpg", sha256: "ab", mime: "image/jpeg", preview: "https://c/1.jpg", status: "done" })
  assert.deepEqual(recipeFromDraft({ title: 5 }), EMPTY_RECIPE)
})

test("New Post offers Recipe after Article; ?type=recipe opens it; Recipes' button goes there", () => {
  assert.deepEqual(COMPOSE_TYPES.map(([t]) => t), ["note", "article", "recipe", "poll", "highlight"])
  assert.equal(composeType("#/compose?type=recipe"), "recipe")
  assert.equal(composeHref("recipe"), "#/compose?type=recipe")
  const a = RecipeButton()
  assert.equal(a.props.href, "#/compose?type=recipe")
  assert.equal(a.props["aria-label"], "Post a recipe")
})

test("publishKind signs, stores and sends the recipe as a kind 30023", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const stored = [], sent = []
  const vault = { outbox: { event: async e => { stored.push(e); return { ok: true } } } }
  t.mock.method(pool, "publish", (urls, ev) => { sent.push({ urls, ev }); return urls.map(() => Promise.resolve("")) })
  const { content, tags } = buildRecipe(full, { identifier: "shakshuka-000000", publishedAt: 5 })
  const res = await publishKind(vault, { signEvent: async tpl => finalizeEvent(tpl, sk) }, pk, LONG_FORM_KIND, content, ["wss://w.example"], tags)
  assert.equal(res.event.kind, 30023)
  assert.ok(verifyEvent(res.event))
  assert.ok(isRecipe(res.event.tags))
  assert.deepEqual(stored.map(e => e.id), [res.event.id])
  assert.ok(sent[0].urls.includes("wss://w.example"))
})
