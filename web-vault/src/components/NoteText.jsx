// Plain text with links, inline images and video, and short nostr: references. No embeds in M1.
import { npubEncode } from "nostr-tools/nip19"

const TOKEN = /(https?:\/\/[^\s<>"]+|nostr:[a-z0-9]+)/gi
const IMAGE = /\.(png|jpe?g|gif|webp|avif)(\?\S*)?$/i
const VIDEO = /\.(mp4|webm|mov)(\?\S*)?$/i

export function NoteText({ content }) {
  const parts = String(content).split(TOKEN)
  return (
    <div class="note-text">
      {parts.map((s, i) => {
        if (i % 2 === 0) return s
        if (s.startsWith("nostr:")) return <span key={i} class="mention">{shortRef(s.slice(6))}</span>
        if (IMAGE.test(s)) return <img key={i} class="note-media" src={s} alt="" loading="lazy" />
        if (VIDEO.test(s)) return <video key={i} class="note-media" src={s} controls preload="metadata" playsinline />
        return <a key={i} href={s} target="_blank" rel="noopener noreferrer">{s.replace(/^https?:\/\//, "").slice(0, 48)}{s.length > 56 ? "…" : ""}</a>
      })}
    </div>
  )
}

function shortRef(ref) {
  if (/^[0-9a-f]{64}$/.test(ref)) ref = npubEncode(ref)
  return ref.slice(0, 12) + "…"
}
