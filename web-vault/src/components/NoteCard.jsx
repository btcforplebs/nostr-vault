import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { NoteText } from "./NoteText.jsx"
import { useProfile } from "./useProfile.js"
import { ago } from "./time.js"
import { act, actionContext, actionState, actionTarget, compose, loadSent, onActionState } from "../net/actions.js"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/note-actions.css")

export function AuthorName({ pubkey }) {
  const p = useProfile(pubkey)
  return <span class="author-name">{p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</span>
}

/** A kind 1 note, or a kind 6 repost shown as the reposted note with a "reposted" line. Floating card, as on iOS
 *  (VaultNoteRow), with the iPhone's action row under it: reply, repost, quote, like. A repost's actions act on the
 *  note inside it. No zap: there's no wallet on the web yet. `memoryOnly`: a stranger's note (Global, Hashtag), so
 *  quotes and @names inside it aren't written to Haven /feed. */
export function NoteCard({ event, memoryOnly = false }) {
  if (event.kind === 6) {
    let inner
    try { inner = JSON.parse(event.content) } catch {}
    const target = actionTarget(event)
    return (
      <article class="note" onClick={inner?.id && openThread(inner.id)}>
        <div class="repost-line"><RepostIcon /><a class="author-link" href={profileHref(event.pubkey)}><AuthorName pubkey={event.pubkey} /></a> reposted</div>
        {inner?.pubkey ? <NoteBody event={inner} memoryOnly={memoryOnly} /> : <div class="note-text muted">Repost of a note not included</div>}
        {target && <NoteActions note={target} />}
      </article>
    )
  }
  return <article class="note" onClick={openThread(event.id)}><NoteBody event={event} memoryOnly={memoryOnly} /><NoteActions note={event} /></article>
}

// Tapping a card opens its thread; a tap on a link, a button or a playing video stays with it.
const openThread = id => e => {
  if (e.target.closest("a, button, video, audio")) return
  location.hash = `#/thread/${id}`
}

const profileHref = pubkey => `#/profile/${pubkey}`

function NoteBody({ event, memoryOnly }) {
  return (
    <>
      <div class="note-head">
        <a class="author-link" href={profileHref(event.pubkey)}>
          <Avatar pubkey={event.pubkey} />
          <AuthorName pubkey={event.pubkey} />
        </a>
        <time class="note-time" datetime={new Date(event.created_at * 1000).toISOString()}>{ago(event.created_at)}</time>
      </div>
      <NoteText content={event.content} memoryOnly={memoryOnly} />
    </>
  )
}

/** Reply · Repost · Quote · Like, in the iPhone's order (FeedNoteRow+NoteBody). Not shown before the app is up. */
function NoteActions({ note }) {
  const ctx = actionContext()
  const [s, setS] = useState(() => actionState(note.id))
  useEffect(() => {
    setS(actionState(note.id))
    const off = onActionState(id => { if (id === note.id) setS(actionState(id)) })
    if (ctx) loadSent(ctx, note.id)
    return off
  }, [note.id, !!ctx])
  if (!ctx) return null
  return (
    <div class="note-actions" role="group" aria-label="Note actions">
      <ActionButton label="Reply" icon={ICONS.reply} onClick={() => compose("reply", note)} />
      <ActionButton label="Repost" doneLabel="Reposted" kind="repost" state={s.repost} icon={ICONS.repost} onClick={() => act(ctx, "repost", note)} />
      <ActionButton label="Quote" icon={ICONS.quote} onClick={() => compose("quote", note)} />
      <ActionButton label="Like" doneLabel="Liked" kind="like" state={s.like} icon={ICONS.heart} onClick={() => act(ctx, "like", note)} />
    </div>
  )
}

// state: undefined | "busy" | "sent" | { error }. Sent stays pressed: taking it back (NIP-09) isn't here yet.
function ActionButton({ label, doneLabel, kind, state, icon, onClick }) {
  const sent = state === "sent", busy = state === "busy", error = state?.error
  const name = sent ? doneLabel : error ? `${label} didn't go out: ${error}. Try again` : busy ? `${label}: sending` : label
  return (
    <button type="button" class={`note-action${kind ? " " + kind : ""}${sent ? " sent" : ""}${error ? " failed" : ""}`}
      aria-label={name} title={name} aria-pressed={kind ? sent : undefined} aria-busy={busy || undefined}
      aria-disabled={sent || busy || undefined} onClick={sent || busy ? undefined : onClick}>
      <svg viewBox="0 0 24 24" width="16" height="16" fill={sent && kind === "like" ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d={icon} />
      </svg>
    </button>
  )
}

const ICONS = {
  reply: "M21 11.5a8.4 8.4 0 0 1-9 8.4 9.4 9.4 0 0 1-4-.9L3 20.5l1.4-4.2A8 8 0 0 1 3 11.5 8.6 8.6 0 0 1 12 3a8.6 8.6 0 0 1 9 8.5z",
  repost: "M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3",
  quote: "M14 15c3.5-1 5-3.5 5-7.5V6h-5v5h3M5 15c3.5-1 5-3.5 5-7.5V6H5v5h3",
  heart: "M12 20.5S3.5 15.3 3.5 9.2A4.7 4.7 0 0 1 12 6.4a4.7 4.7 0 0 1 8.5 2.8c0 6.1-8.5 11.3-8.5 11.3z",
}

const RepostIcon = () => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={ICONS.repost} />
  </svg>
)
