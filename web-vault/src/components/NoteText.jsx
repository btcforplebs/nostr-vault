// Plain text with links, inline images and video, named @mentions and quoted notes.
// nostr:npub / nprofile -> the person's name, linking to their profile. nostr:nevent / note / naddr -> the quoted
// note as a card (QuotedNote). A quote inside a quoted note stays a short reference, so cards don't nest forever.
import { npubEncode } from "nostr-tools/nip19"
import { useEffect } from "preact/hooks"
import { useProfile } from "./useProfile.js"
import { fetchProfiles } from "../net/profiles.js"
import { onQuotes, parseRef, quoteSource } from "../net/quotes.js"
import { QuotedNote } from "./QuotedNote.jsx"

const TOKEN = /(https?:\/\/[^\s<>"]+|nostr:[a-z0-9]+)/gi
const IMAGE = /\.(png|jpe?g|gif|webp|avif)(\?\S*)?$/i
const VIDEO = /\.(mp4|webm|mov)(\?\S*)?$/i
const MAX_QUOTE_DEPTH = 1

/** `dm`: the text is a private message, so nothing in it reaches the network on its own: video links stay links
 *  (no preload) and nostr:npub / nprofile stay short text (no profile fetch). Images show as in a note. */
export function NoteText({ content, depth = 0, dm = false }) {
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
        if (s.startsWith("nostr:")) return nostrRef(s.slice(6), i, depth, dm)
        if (IMAGE.test(s)) return <img key={i} class="note-media" src={s} alt="" loading="lazy" />
        if (VIDEO.test(s) && !dm) return <video key={i} class="note-media" src={s} controls preload="metadata" playsinline />
        const label = s.replace(/^https?:\/\//, "")
        return <a key={i} href={s} target="_blank" rel="noopener noreferrer">{label.slice(0, 48)}{label.length > 48 ? "…" : ""}</a>
      })}
    </div>
  )
}

function nostrRef(ref, key, depth, dm) {
  const q = parseRef(ref)
  if (q?.type === "profile") return dm ? <span key={key} class="mention">{shortRef(ref)}</span> : <Mention key={key} pubkey={q.pubkey} />
  if (q && depth < MAX_QUOTE_DEPTH) return <QuotedNote key={key} q={q} short={shortRef(ref)} depth={depth} />
  return <span key={key} class="mention">{shortRef(ref)}</span>
}

/** @name for a pubkey, linking to their profile. Unknown names are fetched once the vault is registered. */
export function Mention({ pubkey }) {
  const p = useProfile(pubkey)
  useEffect(() => {
    const load = () => { const src = quoteSource(); if (src) fetchProfiles(src.vault, [pubkey], src.relays).catch(() => {}) }
    load()
    return onQuotes(load) // again once main.jsx registers the vault
  }, [pubkey])
  return <a class="mention" href={`#/profile/${pubkey}`} onClick={e => e.stopPropagation()}>@{p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</a>
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
