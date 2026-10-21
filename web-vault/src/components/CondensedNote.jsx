// One note on one line, as on the iPhone (CondensedNoteLine): avatar, name, time, a few lines of plain text and a
// thumbnail of its first photo or video. A click opens the thread, as a full card does. A repost shows the note it
// carries, with who reposted it. `depth` (0 for a root) indents a reply inside a thread card and narrows it.
import { Avatar } from "./Avatar.jsx"
import { AuthorName, Undeleted } from "./NoteCard.jsx"
import { ago } from "./time.js"
import { mediaType, mediaUrls, tileNote } from "../net/media.js"
import { gateIds } from "../net/actions.js"
import { rememberNote } from "../desktop/noteIndex.js"

const URL_RE = /https?:\/\/[^\s<>"]+/gi
const NOSTR_RE = /nostr:(npub|nprofile|note|nevent|naddr)1[a-z0-9]+/gi

/** The text as one plain paragraph: links and media URLs out (media shows as the thumbnail), nostr: refs shortened. */
export function plainText(content) {
  return String(content ?? "")
    .replace(URL_RE, "")
    .replace(NOSTR_RE, m => m.startsWith("nostr:npub") || m.startsWith("nostr:nprofile") ? "@…" : "")
    .replace(/\s+/g, " ").trim()
}

/** Gone at once when this account deletes it, as a full card is (NoteCard Undeleted). */
export function CondensedNote(props) {
  return <Undeleted ids={gateIds(props.event)}><Line {...props} /></Undeleted>
}

function Line({ event, depth = 0, lines, card = false }) {
  const note = tileNote(event) ?? event
  const reposter = event.kind === 6 ? event.pubkey : null
  rememberNote(note)
  const media = mediaUrls(note)
  const text = plainText(note.content)
  const root = depth === 0
  return (
    <div class={`condensed${card ? " condensed-card" : ""}${root ? " root" : " reply"}`} data-note-id={note.id}
      style={depth ? `--indent: ${Math.min(depth, 4) * 14}px` : undefined} role="link" tabIndex={0}
      aria-label={`Open note`} onClick={open(note.id)} onAuxClick={open(note.id)} onKeyDown={e => { if (e.key === "Enter") open(note.id)(e) }}>
      {depth > 0 && <span class="condensed-rail" aria-hidden="true" />}
      <a class="condensed-avatar" href={`#/profile/${note.pubkey}`} aria-label="Profile"><Avatar pubkey={note.pubkey} size={root ? 32 : 26} /></a>
      <div class="condensed-main">
        <div class="condensed-head">
          <AuthorName pubkey={note.pubkey} />
          <time datetime={new Date(note.created_at * 1000).toISOString()} title={new Date(note.created_at * 1000).toLocaleString()}>· {ago(note.created_at)}</time>
          {reposter && <span class="condensed-repost">↻ <AuthorName pubkey={reposter} /></span>}
        </div>
        {text && <p class="condensed-text" style={`-webkit-line-clamp: ${lines ?? 3}`}>{text}</p>}
        {!text && !media.length && <p class="condensed-text muted">(no text)</p>}
      </div>
      {media.length > 0 && <Thumb url={media[0]} more={media.length - 1} big={root} />}
    </div>
  )
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

// As a card's: a click opens the thread, a link or button stays with itself, ⌘/Ctrl or middle-click opens a new tab.
const open = id => e => {
  if (e.target.closest("a, button")) return
  if (e.type === "auxclick" && e.button !== 1) return
  if (e.metaKey || e.ctrlKey || e.button === 1) { globalThis.open(`#/thread/${id}`, "_blank", "noopener"); return }
  location.hash = `#/thread/${id}`
}
