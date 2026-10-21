// A note quoted inside another (nostr:nevent / note / naddr): author, time and text in an inset card, read from
// Haven /feed first and the relays after. Tapping it opens that note's thread, not the note around it.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "./Avatar.jsx"
import { AuthorName } from "./NoteCard.jsx"
import { NoteText } from "./NoteText.jsx"
import { ago } from "./time.js"
import { fetchProfiles } from "../net/profiles.js"
import { getBlocks, isBlockedNote, onBlocks } from "../net/blocks.js"
import { fetchQuote, getQuote, hasQuote, onQuotes, quoteHash, quoteKey, quoteSource } from "../net/quotes.js"

/** The cached event for a parsed reference (undefined while loading, null when not found), fetching it once.
 *  `memoryOnly`: the card is a stranger's, so what the relays return isn't written to Haven /feed. */
/** The blocked set, kept current. */
export function useBlocked() {
  const [blocked, setBlocked] = useState(() => getBlocks().blocked)
  useEffect(() => onBlocks(() => setBlocked(getBlocks().blocked)), [])
  return blocked
}

export function useQuote(q, memoryOnly = false) {
  const key = quoteKey(q)
  const [ev, setEv] = useState(() => getQuote(key))
  useEffect(() => {
    setEv(getQuote(key))
    // Runs now and whenever a quote lands or the vault is registered (main.jsx may do that after the first render).
    const load = () => {
      if (hasQuote(key)) return setEv(getQuote(key))
      const src = quoteSource()
      if (src) fetchQuote(q, { ...src, save: !memoryOnly }).catch(() => {})
    }
    load()
    return onQuotes(load)
  }, [key])
  return ev
}

export function QuotedNote({ q, short, depth = 0, memoryOnly = false }) {
  const ev = useQuote(q, memoryOnly)
  // Someone you blocked says nothing inside another's note either (QuotedNoteView's blocked placeholder).
  const blocked = useBlocked()
  // A quote no relay answers for gives up after 12 s, as the iPhone's does, instead of loading forever.
  const [late, setLate] = useState(false)
  useEffect(() => { const t = setTimeout(() => setLate(true), 12_000); return () => clearTimeout(t) }, [quoteKey(q)])
  useEffect(() => {
    const src = quoteSource()
    if (ev && src) fetchProfiles(src.vault, [ev.pubkey], src.relays, { save: !memoryOnly }).catch(() => {})
  }, [ev?.pubkey])

  if (ev === undefined && late) return <div class="quote quote-missing">Quoted note unavailable</div>
  if (ev === undefined) return <div class="quote quote-pending"><span class="quote-ref">{short}</span> Loading…</div>
  if (ev === null) return <div class="quote quote-missing"><span class="quote-ref">{short}</span> Note not found</div>
  if (blocked && isBlockedNote(ev, blocked)) return <div class="quote quote-missing">Quote from someone you blocked</div>

  const open = e => {
    if (e.target.closest("a, button, video, audio, .media-box")) return
    e.stopPropagation() // the card around this one opens its own thread on a tap
    location.hash = quoteHash(ev)
  }
  const title = ev.tags?.find(t => t[0] === "title")?.[1]
  return (
    <div class="quote" role="link" tabIndex={0} onClick={open} onKeyDown={e => e.key === "Enter" && open(e)}>
      <div class="note-head">
        <Avatar pubkey={ev.pubkey} size={24} />
        <AuthorName pubkey={ev.pubkey} />
        <time class="note-time" datetime={new Date(ev.created_at * 1000).toISOString()}>{ago(ev.created_at)}</time>
      </div>
      {title && <strong class="quote-title">{title}</strong>}
      <NoteText content={title ? ev.tags.find(t => t[0] === "summary")?.[1] || ev.content : ev.content} tags={title ? undefined : ev.tags} author={ev.pubkey} depth={depth + 1} memoryOnly={memoryOnly} />
    </div>
  )
}
