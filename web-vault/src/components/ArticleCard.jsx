// A kind 30023 long-form article (NIP-23): image, title, date and summary; tap to show the body as plain text.
// Markdown is not rendered in M1, so the body keeps its line breaks and nothing else. "Open in YakiHonne" (zap.cooking
// for a recipe) under the date, as the iPhone's ArticleCardView offers on long-press.
import { useState } from "preact/hooks"
import { eventWebLink } from "../net/web-link.js"
import { ago } from "./time.js"

export function ArticleCard({ event }) {
  const [open, setOpen] = useState(false)
  const tag = k => event.tags.find(t => t[0] === k)?.[1]
  const published = Number(tag("published_at")) || event.created_at
  const summary = tag("summary")
  const image = tag("image")
  const link = eventWebLink(event)
  return (
    <article class="article" aria-expanded={open} onClick={() => setOpen(!open)}>
      {image && <img class="article-image" src={image} alt="" loading="lazy" />}
      <h3>{tag("title") || "Untitled"}</h3>
      <time class="muted" datetime={new Date(published * 1000).toISOString()}>{ago(published)}</time>
      {link && <> · <a class="small" href={link.url} target="_blank" rel="noopener noreferrer" onClick={e => e.stopPropagation()}>Open in {link.site}</a></>}
      {open ? <div class="article-body">{event.content}</div> : summary && <p>{summary}</p>}
    </article>
  )
}
