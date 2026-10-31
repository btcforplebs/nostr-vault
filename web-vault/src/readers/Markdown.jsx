// A long-form body drawn from parseMarkdown's blocks (the iPhone's MarkdownBodyView). Everything is built as
// elements from parsed text, never as HTML, so nothing in an article can run in the page. A tap on an image opens it
// full screen on its own (MarkdownBodyView onImageTap -> the media viewer with just that URL).
import { useState } from "preact/hooks"
import { MediaLightbox } from "../components/MediaLightbox.jsx"
import { imageItem } from "../net/note-media.js"
import { parseMarkdown, parseInline } from "./longform.js"

export function Markdown({ body }) {
  return (
    <div class="md">
      {parseMarkdown(body).map((b, i) => {
        switch (b.type) {
          case "heading": { const H = `h${Math.min(b.level + 1, 6)}`; return <H key={i} class={`md-h md-h${b.level}`}><Inline text={b.text} /></H> }
          case "paragraph": return <p key={i}><Inline text={b.text} /></p>
          case "bullet": return <div key={i} class="md-item"><span class="md-mark">•</span><span><Inline text={b.text} /></span></div>
          case "ordered": return <div key={i} class="md-item"><span class="md-mark">{b.index}.</span><span><Inline text={b.text} /></span></div>
          case "quote": return <blockquote key={i}><Inline text={b.text} /></blockquote>
          case "code": return <pre key={i}><code>{b.text}</code></pre>
          case "image": return <MdImage key={i} url={b.url} />
          default: return <hr key={i} />
        }
      })}
    </div>
  )
}

/** An article image, a button that opens it full screen. */
export function MdImage({ url }) {
  const [open, setOpen] = useState(false)
  return <>
    <button type="button" class="md-image-open" aria-label="View image full screen" onClick={e => { e.stopPropagation(); setOpen(true) }}>
      <img class="md-image" src={url} alt="" loading="lazy" referrerpolicy="no-referrer" />
    </button>
    {open && <MediaLightbox items={[imageItem(url)]} onClose={() => setOpen(false)} />}
  </>
}

export function Inline({ text }) {
  return parseInline(text).map((p, i) => {
    if (p.type === "strong") return <strong key={i}>{p.text}</strong>
    if (p.type === "em") return <em key={i}>{p.text}</em>
    if (p.type === "code") return <code key={i}>{p.text}</code>
    if (p.type === "link") return <a key={i} href={p.url} target="_blank" rel="noopener noreferrer" onClick={e => e.stopPropagation()}>{p.text}</a>
    return p.text
  })
}
