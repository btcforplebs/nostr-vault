// Plain text with links, inline images and video, and short nostr: references. No embeds in M1.
import { npubEncode } from "nostr-tools/nip19"

const TOKEN = /(https?:\/\/[^\s<>"]+|nostr:[a-z0-9]+)/gi
const IMAGE = /\.(png|jpe?g|gif|webp|avif)(\?\S*)?$/i
const VIDEO = /\.(mp4|webm|mov)(\?\S*)?$/i

export function NoteText({ content }) {
  const parts = String(content).split(TOKEN)
  // Punctuation that ends a sentence goes back into the text after the link.
  for (let i = 1; i < parts.length; i += 2) {
    const url = trimUrl(parts[i])
    parts[i + 1] = parts[i].slice(url.length) + parts[i + 1]
    parts[i] = url
  }
  return (
    <div class="note-text">
      {parts.map((s, i) => {
        if (i % 2 === 0) return s
        if (s.startsWith("nostr:")) return <span key={i} class="mention">{shortRef(s.slice(6))}</span>
        if (IMAGE.test(s)) return <img key={i} class="note-media" src={s} alt="" loading="lazy" />
        if (VIDEO.test(s)) return <video key={i} class="note-media" src={s} controls preload="metadata" playsinline />
        const label = s.replace(/^https?:\/\//, "")
        return <a key={i} href={s} target="_blank" rel="noopener noreferrer">{label.slice(0, 48)}{label.length > 48 ? "…" : ""}</a>
      })}
    </div>
  )
}

// Drops trailing .,;:!? and any ")" without a matching "(" in the link, so "(see https://x.com/a)." links to https://x.com/a.
function trimUrl(s) {
  for (;;) {
    const last = s.at(-1)
    if (".,;:!?".includes(last)) s = s.slice(0, -1)
    else if (last === ")" && s.split(")").length > s.split("(").length) s = s.slice(0, -1)
    else return s
  }
}

function shortRef(ref) {
  if (/^[0-9a-f]{64}$/.test(ref)) ref = npubEncode(ref)
  return ref.slice(0, 12) + "…"
}
