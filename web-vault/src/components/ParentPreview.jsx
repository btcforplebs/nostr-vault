// The note a reply answers, above it in the feed, as on the iPhone (FeedNoteRow+Layout "Parent Note Preview"): the
// parent's avatar with a thread line down to the reply, its name, time, two lines of text and its first photo. A
// click opens the parent's thread. Placeholder while it loads; after 12 s with nothing, "Could not load original
// note" and Retry. Read from Haven /feed, then the relays (the e tag's hint too); `memoryOnly` writes nothing.
import { useEffect, useState } from "preact/hooks"
import { AvatarMenu } from "./AuthorQuickMenu.jsx"
import { AuthorName } from "./NoteCard.jsx"
import { Badges } from "./Badges.jsx"
import { useQuote } from "./QuotedNote.jsx"
import { ago } from "./time.js"
import { plainText } from "./CondensedNote.jsx"
import { mediaType, mediaUrls } from "../net/media.js"
import { fetchQuote, forgetQuote, quoteSource } from "../net/quotes.js"

export const PARENT_TIMEOUT_MS = 12_000

export function ParentPreview({ id, relay, memoryOnly = false }) {
  const q = { type: "note", id, relays: relay ? [relay] : [] }
  const ev = useQuote(q, memoryOnly)
  const [late, setLate] = useState(false)
  const [tries, setTries] = useState(0)
  useEffect(() => {
    setLate(false)
    const t = setTimeout(() => setLate(true), PARENT_TIMEOUT_MS)
    return () => clearTimeout(t)
  }, [id, tries])
  const retry = e => {
    e.stopPropagation()
    forgetQuote(id)
    const src = quoteSource()
    if (src) fetchQuote(q, { ...src, save: !memoryOnly }).catch(() => {})
    setTries(tries + 1)
  }
  if (ev?.kind === 1) {
    const media = mediaUrls(ev).filter(u => mediaType(u) === "image")
    const text = plainText(ev.content)
    const open = e => { if (e.target.closest("a, button")) return; e.stopPropagation(); location.hash = `#/thread/${ev.id}` }
    return (
      <div class="parent-preview" role="link" tabIndex={0} aria-label="Open the note this replies to" onClick={open} onKeyDown={e => e.key === "Enter" && open(e)}>
        <div class="parent-rail"><AvatarMenu pubkey={ev.pubkey} /><span class="parent-line" aria-hidden="true" /></div>
        <div class="parent-main">
          <div class="parent-head">
            <a class="parent-name" href={`#/profile/${ev.pubkey}`} onClick={e => e.stopPropagation()}><AuthorName pubkey={ev.pubkey} /></a>
            <Badges pubkey={ev.pubkey} note={ev} />
            <time datetime={new Date(ev.created_at * 1000).toISOString()}>{ago(ev.created_at)}</time>
          </div>
          {text && <p class="parent-text">{text}</p>}
          {media[0] && <img class="parent-media" src={media[0]} alt="" loading="lazy" referrerpolicy="no-referrer" onError={e => e.currentTarget.remove()} />}
        </div>
      </div>
    )
  }
  if (ev === null || late) {
    return (
      <div class="parent-failed">
        <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M12 3 2 20h20zM12 10v4M12 17v.5" /></svg>
        <span>Could not load original note</span>
        <button type="button" onClick={retry}>Retry</button>
      </div>
    )
  }
  return (
    <div class="parent-preview loading" aria-label="Loading original note" aria-busy="true">
      <div class="parent-rail"><span class="sk-avatar" /><span class="parent-line" aria-hidden="true" /></div>
      <div class="parent-main"><span class="sk-bar" style="width: 110px; margin-top: 6px" /><span class="sk-bar" /><span class="sk-bar" style="width: 70%" /></div>
    </div>
  )
}
