// The media viewer's swipe up (Logen 2026-11-04; iPhone FeedMediaViewer's notes sheet): the notes on your vault that
// use the photo or video on screen, newest first (net/media-notes.js, as the Vault gallery's "Posted in N notes").
// Read from this browser's vault only; nothing is asked of the network. A row opens the note.
import { useEffect, useState } from "preact/hooks"
import { vaultNotesUsing, notePreview } from "../net/media-notes.js"
import { Avatar } from "./Avatar.jsx"
import { useProfile } from "./useProfile.js"
import { ago } from "./time.js"

export function MediaNotesSheet({ vault, item, onOpen, onClose }) {
  const [notes, setNotes] = useState(null)
  useEffect(() => {
    let live = true
    setNotes(null)
    vaultNotesUsing(vault, { url: item.url, sha256: item.x }).then(n => { if (live) setNotes(n) }, () => { if (live) setNotes([]) })
    return () => { live = false }
  }, [item.url, item.x])
  return (
    <div class="lightbox-notes" role="region" aria-label="Notes that use this">
      <div class="lightbox-notes-head">
        <span class="small">{notes === null ? "Looking for notes that use it…" : !notes.length ? "No note on your vault uses this file." : `Posted in ${notes.length === 1 ? "1 note" : `${notes.length} notes`}`}</span>
        <button type="button" class="small" onClick={onClose}>Done</button>
      </div>
      {notes?.map(n => <Row key={n.id} note={n} onOpen={onOpen} />)}
    </div>
  )
}

function Row({ note, onOpen }) {
  const p = useProfile(note.pubkey)
  return (
    <a class="lightbox-note" href={`#/thread/${note.id}`} onClick={() => onOpen?.()}>
      <Avatar pubkey={note.pubkey} size={28} />
      <span class="lightbox-note-text">
        <span class="small"><b>{p?.display_name || p?.name || note.pubkey.slice(0, 8)}</b> <span class="muted">· {ago(note.created_at)}</span></span>
        <span class="muted small lightbox-note-preview">{notePreview(note.content)}</span>
      </span>
    </a>
  )
}
