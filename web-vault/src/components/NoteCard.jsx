import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Mention, NoteText } from "./NoteText.jsx"
import { useBlocked, useQuote } from "./QuotedNote.jsx"
import { repostState } from "../net/blocks.js"
import { useProfile } from "./useProfile.js"
import { ago } from "./time.js"
import { ZapButton } from "./ZapButton.jsx"
import { MoreMenu } from "./Moderation.jsx"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { act, actionContext, actionState, actionTarget, compose, gateIds, isDeleted, loadSent, onActionState } from "../net/actions.js"
import { rememberNote } from "../desktop/noteIndex.js"
import { replyRefs, replyToPubkey, repostInner, repostedId } from "../net/thread.js"
import { Badges } from "./Badges.jsx"
import { ParentPreview } from "./ParentPreview.jsx"
import { KindBody, hasKindBody } from "./FeedKinds.jsx"
import { GENERIC_REPOST_KIND, SHOWN_REPOST_KINDS, commentParentAuthor, genericRepostInner, repostRef } from "../net/feed-kinds.js"
import { TranslateButton } from "./TranslateButton.jsx"
import { EventInfoButton } from "./EventInfo.jsx"
import { AvatarMenu } from "./AuthorQuickMenu.jsx"
import { ReactionButton } from "./ReactionButton.jsx"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/note-actions.css")

export function AuthorName({ pubkey }) {
  const p = useProfile(pubkey)
  return <span class="author-name">{p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</span>
}

/** A kind 1 note, or a kind 6 repost shown as the reposted note with a "reposted" line. Floating card, as on iOS
 *  (VaultNoteRow), with the iPhone's action row under it: reply, repost, quote, like. A repost's actions act on the
 *  note inside it, zap included. `memoryOnly`: a stranger's note (Global, Hashtag), so quotes and @names inside it
 *  aren't written to Haven /feed. */
export function NoteCard({ event, memoryOnly = false, showParent = false }) {
  return <Undeleted ids={gateIds(event)}>{card(event, memoryOnly, showParent)}</Undeleted>
}

/** Its children, until this account deletes one of `ids` (a post, or the note a repost carries): then nothing, at
 *  once, wherever the card was drawn. */
export function Undeleted({ ids, children }) {
  const key = ids.join()
  const [gone, setGone] = useState(() => ids.some(isDeleted))
  useEffect(() => {
    setGone(ids.some(isDeleted))
    return onActionState(i => { if (ids.includes(i)) setGone(ids.some(isDeleted)) })
  }, [key])
  return gone ? null : children
}

function card(event, memoryOnly, showParent) {
  if (event.kind === GENERIC_REPOST_KIND) return genericRepost(event, memoryOnly)
  if (event.kind === 6) {
    // The embedded note is only as good as whoever reposted it: unsigned or tampered, it is fetched by id instead,
    // so its pubkey never stands in as the author (whose mesh vault a photo would dial).
    const inner = repostInner(event)
    const target = actionTarget(event)
    if (target) rememberNote(target)
    const open = inner?.id ?? repostedId(event)
    return (
      <article class="note" data-note-id={target?.id} onClick={open && openThread(open)} onAuxClick={open && openThread(open)}>
        {repostLine(event)}
        {inner?.pubkey ? <NoteBody event={inner} memoryOnly={memoryOnly} />
          : repostedId(event) ? <FetchedRepost q={{ type: "note", id: repostedId(event), relays: [] }} memoryOnly={memoryOnly} />
          : <div class="note-text muted">Repost of a note not included</div>}
        {target && <NoteActions note={target} />}
      </article>
    )
  }
  rememberNote(event)
  return <article class="note" data-note-id={event.id} onClick={openThread(event.id)} onAuxClick={openThread(event.id)}><NoteBody event={event} memoryOnly={memoryOnly} showParent={showParent} /><NoteActions note={event} /></article>
}

// Tapping a card opens its thread; a tap on a link, a button or a playing video stays with it. A ⌘/Ctrl-click or a
// middle-click opens the thread in a new browser tab, as a link would.
const openThread = id => e => {
  if (e.target.closest("a, button, video, audio, .media-box")) return
  if (e.type === "auxclick" && e.button !== 1) return
  if (e.metaKey || e.ctrlKey || e.button === 1) { open(`#/thread/${id}`, "_blank", "noopener"); return }
  location.hash = `#/thread/${id}`
}

const profileHref = pubkey => `#/profile/${pubkey}`

const repostLine = event =>
  <div class="repost-line"><RepostIcon /><a class="author-link" href={profileHref(event.pubkey)}><AuthorName pubkey={event.pubkey} /></a> reposted</div>

/** A NIP-18 generic repost (kind 16): a repost of anything but a text note, drawn as its own kind, as iOS holds it as
 *  a 6 and draws the original. The embedded copy is used only when its signature checks out (an article, poll or
 *  picture is not a note's text, so an unchecked copy could put words in someone's mouth); else it is fetched by its
 *  e tag or a coordinate. */
function genericRepost(event, memoryOnly) {
  const inner = genericRepostInner(event)
  const ref = repostRef(event)
  if (inner) rememberNote(inner)
  const open = inner?.id ?? (ref?.type === "note" ? ref.id : null)
  return (
    <article class="note" data-note-id={inner?.id} onClick={open && openThread(open)} onAuxClick={open && openThread(open)}>
      {repostLine(event)}
      {inner ? <><NoteBody event={inner} memoryOnly={memoryOnly} /><NoteActions note={inner} /></>
        : ref ? <FetchedRepost q={ref} memoryOnly={memoryOnly} kinds={SHOWN_REPOST_KINDS} />
        : <div class="note-text muted">Repost of a post not included</div>}
    </article>
  )
}

/** A repost that carried only the e tag (FeedNoteRow+NoteBody fetches the original the same way): the note it points
 *  at, from Haven /feed or the relays, with its own actions. `kinds`: what it may be (a kind 6: a note; a kind 16:
 *  any kind a timeline draws). */
const NOTE_ONLY = new Set([1])
function FetchedRepost({ q, memoryOnly, kinds = NOTE_ONLY }) {
  const ev = useQuote(q, memoryOnly), state = repostState(ev, kinds, useBlocked())
  if (state === "loading") return <div class="note-text muted">Loading the reposted note…</div>
  if (state === "missing") return <div class="note-text muted">The reposted note couldn't be found</div>
  if (state === "blocked") return <div class="note-text muted">Repost of someone you blocked</div>
  rememberNote(ev)
  return <><NoteBody event={ev} memoryOnly={memoryOnly} /><NoteActions note={ev} /></>
}

function NoteBody({ event, memoryOnly, showParent = false }) {
  const replyTo = replyToPubkey(event) ?? commentParentAuthor(event)
  const parent = showParent && event.kind === 1 ? replyRefs(event).parent : null
  const hint = parent && (event.tags ?? []).find(t => t[0] === "e" && t[1] === parent)?.[2]
  return (
    <>
      {parent && <ParentPreview id={parent} relay={/^wss?:\/\//.test(hint ?? "") ? hint : null} memoryOnly={memoryOnly} />}
      <div class="note-head">
        <AvatarMenu pubkey={event.pubkey} />
        <a class="author-link" href={profileHref(event.pubkey)}>
          <AuthorName pubkey={event.pubkey} />
        </a>
        <Badges pubkey={event.pubkey} note={event} />
        <time class="note-time" datetime={new Date(event.created_at * 1000).toISOString()} title={new Date(event.created_at * 1000).toLocaleString()}>{ago(event.created_at)}</time>
      </div>
      {replyTo && <div class="reply-to"><ReplyIcon />reply to <Mention pubkey={replyTo} memoryOnly={memoryOnly} /></div>}
      {hasKindBody(event) ? <KindBody event={event} memoryOnly={memoryOnly} /> : <NoteText content={event.content} tags={event.tags} author={event.pubkey} memoryOnly={memoryOnly} linkCards />}
      {event.kind === 1 && <TranslateButton id={event.id} content={event.content} />}
    </>
  )
}

/** Reply · Repost · Quote · Like · Zap, in the iPhone's order (FeedNoteRow+NoteBody), then ⋯ (report, block) at the
 *  far end. Not shown before the app is up. */
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
  const off = ctx.signer?.readOnly ? READ_ONLY_SHORT : "" // greyed out with the reason, rather than failing after a tap
  return (
    <div class="note-actions" role="group" aria-label="Note actions">
      <ActionButton label="Reply" off={off} icon={ICONS.reply} onClick={() => compose("reply", note)} />
      <ActionButton label="Repost" off={off} doneLabel="Reposted" kind="repost" state={s.repost} icon={ICONS.repost} onClick={() => act(ctx, "repost", note)} />
      <ActionButton label="Quote" off={off} icon={ICONS.quote} onClick={() => compose("quote", note)} />
      <ReactionButton ctx={ctx} note={note} state={s.like} off={off} />
      <ZapButton note={note} />
      <EventInfoButton event={note} account={ctx.account} />
      {!off && <span class="note-actions-end"><MoreMenu note={note} className="note-action" /></span>}
    </div>
  )
}

// state: undefined | "busy" | "sent" | { error, unlike? }. Sent stays pressed; with `undo` (Like) a tap on it takes it back.
function ActionButton({ label, doneLabel, kind, state, icon, onClick, off = "", undo = false }) {
  const sent = state === "sent", busy = state === "busy", error = state?.error
  if (off) onClick = undefined
  const name = off ? `${label}. ${off}` : sent ? doneLabel : error ? `${state.unlike ? "Unlike" : label} didn't go out: ${error}. Try again` : busy ? `${label}: sending` : label
  return (
    <button type="button" class={`note-action${kind ? " " + kind : ""}${sent ? " sent" : ""}${error ? " failed" : ""}${off ? " off" : ""}`}
      aria-label={name} title={name} aria-pressed={kind ? sent : undefined} aria-busy={busy || undefined}
      aria-disabled={(sent && !undo) || busy || !!off || undefined} onClick={(sent && !undo) || busy ? undefined : onClick}>
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

// The iPhone's arrowshape.turn.up.left.fill, small, before "reply to @name".
const ReplyIcon = () => (
  <svg viewBox="0 0 24 24" width="11" height="11" fill="currentColor" aria-hidden="true"><path d="M10 4 3 11l7 7v-4.2c5 0 8.4 1.6 11 5.2-1-5-4-10-11-11V4z" /></svg>
)

const RepostIcon = () => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={ICONS.repost} />
  </svg>
)
