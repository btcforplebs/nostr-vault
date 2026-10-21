// One note on one line, as on the iPhone (CondensedNoteLine): avatar, name, time, a few lines of plain text, a link
// chip, and a thumbnail of its first photo or video. A repost shows the note it carries, with who reposted it.
// `depth` (0 for a root) indents a reply inside a thread card under a rail, and narrows it. With `onOpen` a click
// opens the line in place, as the iPhone's first tap does; without it a click opens the thread.
import { decode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { AuthorName, Undeleted } from "./NoteCard.jsx"
import { Mention } from "./NoteText.jsx"
import { useQuote } from "./QuotedNote.jsx"
import { Badges } from "./Badges.jsx"
import { ago } from "./time.js"
import { mediaType, mediaUrls, tileNote } from "../net/media.js"
import { gateIds } from "../net/actions.js"
import { rememberNote } from "../desktop/noteIndex.js"
import { replyRefs, repostedId } from "../net/thread.js"

const URL_RE = /https?:\/\/[^\s<>"]+/gi
const NOSTR_RE = /nostr:(npub|nprofile|note|nevent|naddr)1[a-z0-9]+/gi

/** The text as one plain paragraph: links and media URLs out (media shows as the thumbnail), nostr: refs shortened. */
export function plainText(content) {
  return textParts(content).map(p => typeof p === "string" ? p : "@…").join("").replace(/\s+/g, " ").trim()
}

/** The plain paragraph as strings and { pubkey } for each @mention, so a line can show the name (the iPhone's
 *  resolveMentionsPlainText). Quoted notes and links drop out: the header's quote mark and the link chip say so. */
export function textParts(content) {
  const text = String(content ?? "").replace(URL_RE, "").replace(/\s+/g, " ").trim()
  const parts = []
  let at = 0
  for (const m of text.matchAll(NOSTR_RE)) {
    parts.push(text.slice(at, m.index))
    at = m.index + m[0].length
    const pk = mentionPubkey(m[0])
    if (pk !== null) parts.push({ pubkey: pk })
  }
  parts.push(text.slice(at))
  const out = parts.filter(p => p !== "")
  if (typeof out[0] === "string") out[0] = out[0].trimStart()
  if (typeof out.at(-1) === "string") out[out.length - 1] = out.at(-1).trimEnd()
  return out.filter(p => p !== "")
}

// "" for an npub that doesn't decode: still an @, with no name to show.
function mentionPubkey(ref) {
  if (!/^nostr:(npub|nprofile)/.test(ref)) return null
  try {
    const d = decode(ref.slice(6))
    return d.type === "npub" ? d.data : d.data.pubkey
  } catch { return "" }
}

/** Links in the text that aren't media, once each: the condensed stand-in for link cards. */
export function linkUrls(note) {
  const urls = (String(note.content ?? "").match(URL_RE) ?? []).map(u => u.replace(/[.,;:!?)]+$/, ""))
  return [...new Set(urls)].filter(u => !mediaType(u))
}

export const domainOf = url => { try { return new URL(url).hostname.replace(/^www\./, "") } catch { return url } }

/** It quotes another note: a q tag, or a nostr:note / nevent in its text (the full card's Quote). */
export const quotes = note => (note.tags ?? []).some(t => t[0] === "q") || /nostr:(note|nevent)1/.test(note.content ?? "")

export { fromNostrVault } from "./Badges.jsx"

/** Gone at once when this account deletes it, as a full card is (NoteCard Undeleted). */
export function CondensedNote(props) {
  return <Undeleted ids={gateIds(props.event)}><Line {...props} /></Undeleted>
}

function Line(props) {
  const { event } = props
  const inner = tileNote(event)
  // A bare repost carries only the e tag: show the note it points at once it lands, as the full card does.
  if (event.kind === 6 && !inner && repostedId(event)) return <BareRepost {...props} id={repostedId(event)} />
  return <Row {...props} note={inner ?? event} />
}

function BareRepost(props) {
  const ev = useQuote({ type: "note", id: props.id, relays: [] }, true)
  if (ev?.kind === 1) return <Row {...props} note={ev} />
  return <Row {...props} note={props.event} placeholder={ev === undefined ? "Loading the reposted note…" : "The reposted note is unavailable"} />
}

function Row({ event, note, placeholder, depth = 0, lines, card = false, onOpen }) {
  const reposter = event.kind === 6 ? event.pubkey : null
  if (!placeholder) rememberNote(note)
  const media = placeholder ? [] : mediaUrls(note)
  const links = placeholder ? [] : linkUrls(note)
  const parts = placeholder ? [placeholder] : textParts(note.content)
  const root = depth === 0
  const go = onOpen && !placeholder ? tap(note.id, () => onOpen(note)) : open(note.id)
  return (
    <div class={`condensed${card ? " condensed-card" : ""}${root ? " root" : " reply"}`} data-note-id={note.id}
      style={depth ? `--indent: ${Math.min(depth, 4) * 14}px` : undefined} role="button" tabIndex={0}
      aria-label={label(note, depth)} onClick={go} onAuxClick={open(note.id)} onKeyDown={e => { if (e.key === "Enter") go(e) }}>
      {depth > 0 && <span class="condensed-rail" aria-hidden="true" />}
      <a class="condensed-avatar" href={`#/profile/${note.pubkey}`} aria-label="Profile"><Avatar pubkey={note.pubkey} size={root ? 32 : 26} /></a>
      <div class="condensed-main">
        <div class="condensed-head">
          <a class="condensed-name" href={`#/profile/${note.pubkey}`}><AuthorName pubkey={note.pubkey} /></a>
          <Badges pubkey={note.pubkey} note={note} />
          <time datetime={new Date(note.created_at * 1000).toISOString()} title={new Date(note.created_at * 1000).toLocaleString()}>· {ago(note.created_at)}</time>
          <span class="condensed-marks">
            {root && note.kind === 1 && replyRefs(note).parent && <Mark kind="reply" />}
            {reposter && <span class="condensed-repost"><Mark kind="repost" /><AuthorName pubkey={reposter} /></span>}
            {!placeholder && quotes(note) && <Mark kind="quote" />}
          </span>
        </div>
        {parts.length > 0 && <p class={`condensed-text${placeholder ? " muted" : ""}`} style={`-webkit-line-clamp: ${lines ?? 3}`}>
          {parts.map((p, i) => typeof p === "string" ? p : p.pubkey ? <Mention key={i} pubkey={p.pubkey} memoryOnly /> : <span key={i} class="mention">@…</span>)}
        </p>}
        {!parts.length && !media.length && !links.length && <p class="condensed-text muted">(no text)</p>}
        {links.length > 0 && <span class="condensed-link"><LinkIcon />{domainOf(links[0])}{links.length > 1 && <b>+{links.length - 1}</b>}</span>}
      </div>
      {media.length > 0 && <Thumb url={media[0]} more={media.length - 1} big={root} />}
    </div>
  )
}

const MARKS = {
  reply: ["Reply", "M10 4 3 11l7 7v-4.2c5 0 8.4 1.6 11 5.2-1-5-4-10-11-11V4z", true],
  repost: ["Repost", "M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3", false],
  quote: ["Quote", "M14 15c3.5-1 5-3.5 5-7.5V6h-5v5h3M5 15c3.5-1 5-3.5 5-7.5V6H5v5h3", false],
}
/** The iPhone's glyphs on the right of a line's header: it is a reply, a repost, a quote. */
function Mark({ kind }) {
  const [name, d, filled] = MARKS[kind]
  return (
    <svg class={`condensed-mark ${kind}`} viewBox="0 0 24 24" width="10" height="10" role="img" aria-label={name}
      fill={filled ? "currentColor" : "none"} stroke={filled ? "none" : "currentColor"} stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d={d} /></svg>
  )
}

const LinkIcon = () => (
  <svg viewBox="0 0 24 24" width="9" height="9" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true">
    <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
  </svg>
)

function label(note, depth) {
  return [depth ? `Reply, level ${depth}` : "Note", plainText(note.content).slice(0, 120)].filter(Boolean).join(": ")
}

function Thumb({ url, more, big }) {
  const video = mediaType(url) === "video"
  return (
    <span class={`condensed-thumb${big ? " big" : ""}`} aria-hidden="true">
      {video ? <span class="condensed-play">▶</span> : <img src={url} alt="" loading="lazy" referrerpolicy="no-referrer" onError={e => e.currentTarget.classList.add("failed")} />}
      {more > 0 && <span class="condensed-more">+{more}</span>}
    </span>
  )
}

// A click on the line runs `fn`; a link or button stays with itself; ⌘/Ctrl-click still opens the thread in a new tab.
const tap = (id, fn) => e => {
  if (e.target.closest("a, button")) return
  if (e.metaKey || e.ctrlKey) return open(id)(e)
  fn()
}

// As a card's: a click opens the thread, a link or button stays with itself, ⌘/Ctrl or middle-click opens a new tab.
const open = id => e => {
  if (e.target.closest("a, button")) return
  if (e.type === "auxclick" && e.button !== 1) return
  if (e.metaKey || e.ctrlKey || e.button === 1) { globalThis.open(`#/thread/${id}`, "_blank", "noopener"); return }
  location.hash = `#/thread/${id}`
}
