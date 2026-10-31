// What a NIP-23 article (kind 30023) carries, ported from the iPhone's LongFormDraft (Views/LongFormComposeView.swift):
// a `d` slug of the title with a short random suffix, title, summary when written, the cover's URL, published_at, and
// a `t` per #hashtag in the title or body.
import { hashtags } from "../../net/hashtags.js"
import { LONG_FORM_KIND } from "../../readers/longform.js"
export { LONG_FORM_KIND }

/** LongFormDraft.slug: letters and digits kept, every other run one dash, at most 60, "post" when nothing is left. */
export function slug(text) {
  let out = "", dash = false
  for (const ch of String(text ?? "").trim().toLowerCase()) {
    if (/[\p{L}\p{N}]/u.test(ch)) { out += ch; dash = false }
    else if (!dash && out) { out += "-"; dash = true }
  }
  out = out.replace(/-+$/, "")
  return out ? [...out].slice(0, 60).join("") : "post"
}

const suffix = (random = globalThis.crypto) => [...random.getRandomValues(new Uint8Array(3))].map(b => b.toString(16).padStart(2, "0")).join("")

/** The `d` tag: two articles with the same title mustn't replace each other. */
export const articleIdentifier = (title, random) => `${slug(title)}-${suffix(random)}`

/** Publish needs a title and a body; the hint says which is missing, and a fresh form says nothing. */
export const canPublishArticle = a => !!a.title.trim() && !!a.body.trim()
export function articleHint(a) {
  if (canPublishArticle(a) || !hasArticle(a)) return null
  return !a.title.trim() ? "Add a title to publish." : "Write the article to publish."
}
export const hasArticle = a => !!(a.title.trim() || a.summary.trim() || a.body.trim() || a.cover?.url)

/** -> { content, tags } for the kind 30023. `identifier` and `publishedAt` are passed in so tests can pin them. */
export function buildArticle({ title, summary, body, cover }, { identifier = articleIdentifier(title), publishedAt = Math.floor(Date.now() / 1000) } = {}) {
  const t = title.trim(), s = summary.trim()
  const tags = [["d", identifier], ["title", t]]
  if (s) tags.push(["summary", s])
  if (cover?.url) tags.push(["image", cover.url])
  tags.push(["published_at", String(publishedAt)])
  for (const topic of hashtags(`${t} ${body}`)) tags.push(["t", topic])
  return { content: body.trim(), tags }
}

/** What the draft keeps: the fields, and the cover once it's uploaded. */
export const articleDraftOf = a => ({
  title: a.title, summary: a.summary, body: a.body,
  ...(a.cover?.url ? { cover: { url: a.cover.url, sha256: a.cover.sha256, mime: a.cover.mime } } : {}),
})
