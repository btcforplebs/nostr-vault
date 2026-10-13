import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { NoteText } from "./NoteText.jsx"
import { useProfile } from "./useProfile.js"
import { ago } from "./time.js"

export function AuthorName({ pubkey }) {
  const p = useProfile(pubkey)
  return <span class="author-name">{p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</span>
}

/** A kind 1 note, or a kind 6 repost shown as the reposted note with a "reposted" line. */
export function NoteCard({ event }) {
  if (event.kind === 6) {
    let inner
    try { inner = JSON.parse(event.content) } catch {}
    return (
      <article class="note">
        <div class="repost-line">⟲ <AuthorName pubkey={event.pubkey} /> reposted</div>
        {inner?.pubkey ? <NoteBody event={inner} /> : <div class="note-text muted">Repost of a note not included</div>}
      </article>
    )
  }
  return <article class="note"><NoteBody event={event} /></article>
}

function NoteBody({ event }) {
  return (
    <div class="note-row">
      <Avatar pubkey={event.pubkey} />
      <div class="note-main">
        <div class="note-head"><AuthorName pubkey={event.pubkey} /><span class="note-time">{ago(event.created_at)}</span></div>
        <NoteText content={event.content} />
      </div>
    </div>
  )
}
