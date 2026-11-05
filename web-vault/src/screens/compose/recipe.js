// What a recipe carries, ported from the iPhone's LongFormDraft recipe mode (Views/LongFormComposeView.swift): a NIP-23
// long-form post (kind 30023) in the shape zap.cooking publishes, so recipe apps and our Recipes feed list it. The body
// is built from the fields (Chef's notes, Details, Ingredients, Directions); the tags are an article's plus
// zapcooking, nostrcooking and a zapcooking-<category> per category.
import { hashtags } from "../../net/hashtags.js"
import { LONG_FORM_KIND, articleIdentifier, slug } from "./article.js"
export { LONG_FORM_KIND }

export const EMPTY_RECIPE = { title: "", summary: "", body: "", prepTime: "", cookTime: "", servings: "", ingredients: "", directions: "", categories: "", cover: null }
const FIELDS = ["title", "summary", "body", "prepTime", "cookTime", "servings", "ingredients", "directions", "categories"]

/** LongFormComposeView.lines: one item per non-empty line, a pasted bullet (-, *, •) or number ("1." / "1)") dropped,
 *  so the list doesn't print "- - 2 eggs" or "1. 1. Preheat". */
export function lines(text) {
  return String(text ?? "").split("\n").map(line => {
    let l = line.trim()
    if (/^[-*•]/.test(l)) l = l.slice(1)
    const m = /^(\d+)[.)]/.exec(l)
    if (m) l = l.slice(m[0].length)
    return l.trim()
  }).filter(Boolean)
}

/** Publish needs a title, an ingredient and a step. */
export const canPublishRecipe = r => !!r.title.trim() && lines(r.ingredients).length > 0 && lines(r.directions).length > 0
export const hasRecipe = r => FIELDS.some(f => String(r[f] ?? "").trim()) || !!r.cover?.url
/** Why Publish is off, once something is written; a fresh form says nothing. The iPhone's words. */
export function recipeHint(r) {
  if (canPublishRecipe(r) || !hasRecipe(r)) return null
  if (!r.title.trim()) return "Add a title to publish."
  return lines(r.ingredients).length ? "Add at least one step to publish." : "Add at least one ingredient to publish."
}

/** LongFormDraft.content() in recipe mode. */
export function recipeContent(r) {
  const parts = []
  const notes = r.body.trim()
  if (notes) parts.push(`## Chef's notes\n\n${notes}`)
  const details = []
  if (r.prepTime.trim()) details.push(`- ⏲️ Prep time: ${r.prepTime.trim()}`)
  if (r.cookTime.trim()) details.push(`- 🍳 Cook time: ${r.cookTime.trim()}`)
  if (r.servings.trim()) details.push(`- 🍽️ Servings: ${r.servings.trim()}`)
  if (details.length) parts.push(`## Details\n\n${details.join("\n")}`)
  parts.push(`## Ingredients\n\n${lines(r.ingredients).map(l => `- ${l}`).join("\n")}`)
  parts.push(`## Directions\n\n${lines(r.directions).map((l, i) => `${i + 1}. ${l}`).join("\n")}`)
  return parts.join("\n\n")
}

/** -> { content, tags } for the kind 30023. `identifier` and `publishedAt` are passed in so tests can pin them. */
export function buildRecipe(r, { identifier = articleIdentifier(r.title), publishedAt = Math.floor(Date.now() / 1000) } = {}) {
  const t = r.title.trim(), s = r.summary.trim()
  const tags = [["d", identifier], ["title", t]]
  if (s) tags.push(["summary", s])
  if (r.cover?.url) tags.push(["image", r.cover.url])
  tags.push(["published_at", String(publishedAt)])
  const topics = ["zapcooking", "nostrcooking"]
  for (const c of r.categories.split(",")) {
    const sl = slug(c)
    if (sl !== "post") topics.push(`zapcooking-${sl}`)
  }
  topics.push(...hashtags(`${t} ${r.body}`))
  for (const topic of new Set(topics)) tags.push(["t", topic])
  return { content: recipeContent(r), tags }
}

/** What the draft keeps: the fields, and the cover once it's uploaded. */
export const recipeDraftOf = r => ({
  ...Object.fromEntries(FIELDS.map(f => [f, r[f]])),
  ...(r.cover?.url ? { cover: { url: r.cover.url, sha256: r.cover.sha256, mime: r.cover.mime } } : {}),
})
/** A kept draft back into the form. */
export const recipeFromDraft = d => ({
  ...Object.fromEntries(FIELDS.map(f => [f, typeof d?.[f] === "string" ? d[f] : ""])),
  cover: d?.cover?.url ? { ...d.cover, preview: d.cover.url, status: "done" } : null,
})
