import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { NoteText } from "./NoteText.jsx"
import { useProfile } from "./useProfile.js"
import { ago } from "./time.js"

export function AuthorName({ pubkey }) {
  const p = useProfile(pubkey)
  return <span class="author-name">{p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</span>
}

/** A kind 1 note, or a kind 6 repost shown as the reposted note with a "reposted" line. Floating card, as on iOS
 *  (VaultNoteRow). No action row in M1: the actions aren't wired, and a button that does nothing is worse than none. */
export function NoteCard({ event }) {
  if (event.kind === 6) {
    let inner
    try { inner = JSON.parse(event.content) } catch {}
    return (
      <article class="note">
        <div class="repost-line"><RepostIcon /><AuthorName pubkey={event.pubkey} /> reposted</div>
        {inner?.pubkey ? <NoteBody event={inner} /> : <div class="note-text muted">Repost of a note not included</div>}
      </article>
    )
  }
  return <article class="note"><NoteBody event={event} /></article>
}

function NoteBody({ event }) {
  return (
    <>
      <div class="note-head">
        <Avatar pubkey={event.pubkey} />
        <AuthorName pubkey={event.pubkey} />
        <time class="note-time" datetime={new Date(event.created_at * 1000).toISOString()}>{ago(event.created_at)}</time>
      </div>
      <NoteText content={event.content} />
    </>
  )
}

const RepostIcon = () => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3" />
  </svg>
)
