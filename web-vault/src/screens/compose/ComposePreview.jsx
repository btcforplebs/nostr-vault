// The note as it will be posted, drawn by the feed's own renderer (NoteCard's NoteBody: link cards, live stream cards,
// quoted notes, hashtags, mentions), so what you see is what readers get. Built by the same buildPost the Post button
// uses, from the photos that are up; one still uploading shows here once it is. Redrawn a moment after typing stops,
// so a link half typed isn't looked up at every key.
import { Component } from "preact"
import { useEffect, useState } from "preact/hooks"
import { getEventHash } from "nostr-tools/pure"
import { NoteBody } from "../../components/NoteCard.jsx"

export const PREVIEW_DELAY_MS = 350

/** The unsigned kind 1 the preview draws: what buildPost made, by you, now, with its real id (the renderer encodes
 *  ids as nevents, so a made-up one throws). Never signed or sent. */
export function previewEvent(built, pubkey, now = Math.floor(Date.now() / 1000)) {
  const ev = { kind: 1, pubkey, created_at: now, content: built.content, tags: built.tags }
  return { ...ev, id: getEventHash(ev), sig: "" }
}

/** `build()` -> { content, tags } (throws when it can't be built yet); `deps`: what it's built from. */
export function ComposePreview({ build, pubkey, deps, uploading = 0 }) {
  const [event, setEvent] = useState(() => make(build, pubkey))
  useEffect(() => {
    const t = setTimeout(() => setEvent(make(build, pubkey)), PREVIEW_DELAY_MS)
    return () => clearTimeout(t)
  }, deps)
  return (
    <section class="compose-preview" aria-label="Preview" aria-live="polite">
      <p class="compose-preview-label muted small">Preview{uploading > 0 ? ` · ${uploading} uploading, shown when done` : ""}</p>
      {event && event.content.trim()
        ? <PreviewGuard key={event.id}><article class="note note-card compose-preview-card"><NoteBody event={event} /></article></PreviewGuard>
        : <p class="muted small compose-preview-empty">Your note shows here as it will look in the feed.</p>}
    </section>
  )
}

function make(build, pubkey) {
  try { return previewEvent(build(), pubkey) } catch { return null }
}

/** A preview that can't be drawn says so instead of taking the composer (and its Post button) down with it. */
class PreviewGuard extends Component {
  state = { failed: false }
  componentDidCatch() { this.setState({ failed: true }) }
  render() { return this.state.failed ? <p class="muted small compose-preview-empty">This preview couldn't be drawn. Your note is unaffected.</p> : this.props.children }
}
