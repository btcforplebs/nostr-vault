// The notes drawn on screen, by id, so the desktop's right-click menu and shortcuts can act on the card under the
// pointer or the selected row (NoteCard marks its card with data-note-id). Capped: oldest drawn are forgotten first.
const CAP = 3000
const notes = new Map()

export function rememberNote(event) {
  if (!event?.id) return
  notes.delete(event.id)
  notes.set(event.id, event)
  if (notes.size > CAP) notes.delete(notes.keys().next().value)
}

export const noteById = id => notes.get(id) ?? null
