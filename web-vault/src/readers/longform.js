// Long-form posts (NIP-23, kind 30023): what the Articles and Recipes readers share. Ported from the iPhone app:
// LongFormMetadata and MarkdownParser (Models/LongFormContent.swift), FeedFilterEngine.dedupeAddressable,
// VaultNoteScope.isRecipe and NostrWebLink.longForm (Models/NostrWebLink.swift).
import { naddrEncode } from "nostr-tools/nip19"

export const LONG_FORM_KIND = 30023
/** The `t` tags that make a long-form post a recipe (zap.cooking writes both). */
export const RECIPE_TOPICS = ["zapcooking", "nostrcooking"]

const first = (tags, name) => {
  const raw = tags?.find(t => t.length >= 2 && t[0] === name)?.[1]
  const v = typeof raw === "string" ? raw.trim() : ""
  return v || null
}
const httpUrl = s => { try { const u = new URL(s); return /^https?:$/.test(u.protocol) ? u.href : null } catch { return null } }

/** Tag-derived metadata: { title, summary, identifier, image, publishedAt, topics }. `published_at` may carry a
 *  fractional part, so it is read as a number, not an integer. */
export function longFormMeta(ev) {
  const tags = ev?.tags ?? []
  const published = Number(first(tags, "published_at"))
  return {
    title: first(tags, "title"),
    summary: first(tags, "summary"),
    identifier: first(tags, "d"),
    image: httpUrl(first(tags, "image")),
    publishedAt: Number.isFinite(published) && published > 0 ? published : null,
    topics: tags.filter(t => t.length >= 2 && t[0] === "t").map(t => String(t[1]).toLowerCase()),
  }
}

/** The title, else the body's first non-empty line without its # marks, so an untitled article still reads as one. */
export function displayTitle(ev) {
  const { title } = longFormMeta(ev)
  if (title) return title
  const line = String(ev?.content ?? "").split("\n").map(l => l.replace(/^[#\s]+|[#\s]+$/g, "")).find(Boolean)
  return line ? line.slice(0, 120) : "Untitled"
}

/** When it was published, else when the event was signed (unix seconds). */
export const displayDate = ev => longFormMeta(ev).publishedAt ?? ev.created_at

/** Minutes at 200 words a minute, at least 1; null for an empty body. */
export function readingMinutes(body) {
  const words = String(body ?? "").split(/\s+/).filter(Boolean).length
  return words ? Math.max(1, Math.ceil(words / 200)) : null
}

export const isRecipe = tags => (tags ?? []).some(t => t.length >= 2 && t[0] === "t" && RECIPE_TOPICS.includes(String(t[1]).toLowerCase()))

/** One per `kind:pubkey:d` address, the newest edit winning; newest first, ties by id. */
export function dedupeAddressable(evs) {
  const by = new Map()
  for (const ev of evs) {
    const key = `${ev.kind}:${ev.pubkey}:${first(ev.tags, "d") ?? ev.id}`
    const have = by.get(key)
    if (!have || ev.created_at > have.created_at) by.set(key, ev)
  }
  return [...by.values()].sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0))
}

/** "Open in …" for a long-form post: zap.cooking for a recipe, YakiHonne for an article. Null without a `d` tag,
 *  since an naddr needs one. -> { url, site } */
export function longFormLink(ev) {
  const identifier = first(ev?.tags, "d")
  if (ev?.kind !== LONG_FORM_KIND || !identifier || !/^[0-9a-f]{64}$/.test(ev.pubkey ?? "")) return null
  const naddr = naddrEncode({ kind: ev.kind, pubkey: ev.pubkey, identifier })
  return isRecipe(ev.tags)
    ? { url: `https://zap.cooking/recipe/${naddr}`, site: "zap.cooking" }
    : { url: `https://yakihonne.com/article/${naddr}`, site: "YakiHonne" }
}

// --- Markdown: the iPhone's block subset (headings, bullets, numbered items, quotes, code, images, rules,
// paragraphs). Consecutive lines join into one paragraph, so hard-wrapped source doesn't render line by line.

const IMAGE_EXT = /\.(jpe?g|png|gif|webp|heic|bmp)$/i

/** The URL when `text` is only an image: `![alt](url)` or a bare image link. */
export function standaloneImage(text) {
  if (text.startsWith("![") && text.endsWith(")")) {
    const open = text.lastIndexOf("(")
    if (open > 0) return httpUrl(text.slice(open + 1, -1).split(" ")[0])
  }
  if (/\s/.test(text)) return null
  const url = httpUrl(text)
  if (!url) return null
  try { return IMAGE_EXT.test(new URL(url).pathname) ? url : null } catch { return null }
}

/** -> [{ type: "heading", level, text } | { type: "paragraph" | "bullet" | "quote" | "code", text } |
 *      { type: "ordered", index, text } | { type: "image", url } | { type: "rule" }] */
export function parseMarkdown(body) {
  const blocks = []
  let para = [], code = [], fenced = false
  const flush = () => {
    const text = para.join(" ").trim()
    para = []
    if (!text) return
    const url = standaloneImage(text)
    blocks.push(url ? { type: "image", url } : { type: "paragraph", text })
  }
  for (const raw of String(body ?? "").split(/\r?\n|\r/)) {
    const line = raw.trim()
    if (line.startsWith("```")) {
      if (fenced) { blocks.push({ type: "code", text: code.join("\n") }); code = []; fenced = false }
      else { flush(); fenced = true }
      continue
    }
    if (fenced) { code.push(raw); continue }
    if (!line) { flush(); continue }
    // A heading needs whitespace after its #s: a line starting with a hashtag is common in Nostr bodies.
    const h = /^(#{1,6})[ \t]+(.*)$/.exec(line)
    if (h && h[2].trim()) { flush(); blocks.push({ type: "heading", level: h[1].length, text: h[2].trim() }); continue }
    if (line === "---" || line === "***" || line === "___") { flush(); blocks.push({ type: "rule" }); continue }
    if (line.startsWith("> ") || line === ">") { flush(); blocks.push({ type: "quote", text: line.slice(1).trim() }); continue }
    if (/^[-*+] /.test(line)) {
      flush()
      const text = line.slice(2).trim()
      const url = standaloneImage(text)
      blocks.push(url ? { type: "image", url } : { type: "bullet", text })
      continue
    }
    const o = /^(\d{1,3})[.)](.*)$/.exec(line)
    if (o && o[2].trim()) { flush(); blocks.push({ type: "ordered", index: Number(o[1]), text: o[2].trim() }); continue }
    para.push(line)
  }
  if (fenced && code.length) blocks.push({ type: "code", text: code.join("\n") })
  flush()
  return blocks
}

/** Inline markdown -> [{ type: "text" | "strong" | "em" | "code", text } | { type: "link", text, url }].
 *  Only http(s) links become links; anything else stays as its text. */
export function parseInline(text) {
  const out = []
  const re = /(\*\*|__)(.+?)\1|`([^`]+)`|!?\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|(?<![\w*])([*_])(?!\s)(.+?)(?<!\s)\6(?![\w*])|(https?:\/\/[^\s<>()]+[^\s<>().,;:!?])/g
  let at = 0, m
  while ((m = re.exec(text))) {
    if (m.index > at) out.push({ type: "text", text: text.slice(at, m.index) })
    if (m[2] !== undefined) out.push({ type: "strong", text: m[2] })
    else if (m[3] !== undefined) out.push({ type: "code", text: m[3] })
    else if (m[5] !== undefined) {
      const url = httpUrl(m[5])
      out.push(url ? { type: "link", text: m[4] || url, url } : { type: "text", text: m[4] || m[5] })
    } else if (m[7] !== undefined) out.push({ type: "em", text: m[7] })
    else out.push({ type: "link", text: m[8], url: m[8] })
    at = re.lastIndex
  }
  if (at < text.length) out.push({ type: "text", text: text.slice(at) })
  return out
}

/** The body as plain text for a card preview, cut at `limit` characters. */
export function plainText(body, limit = 300) {
  const parts = []
  for (const b of parseMarkdown(body)) {
    if (!b.text || b.type === "code") continue
    parts.push(parseInline(b.text).map(p => p.text).join(""))
    if (parts.join(" ").length >= limit) break
  }
  const joined = parts.join(" ").trim()
  return joined.length > limit ? joined.slice(0, limit) + "…" : joined
}
