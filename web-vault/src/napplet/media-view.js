// napplet:media/view (bug run, tap-to-zoom): the Reader hands over the signed note and the picture tapped; the shell
// opens its own full-screen viewer (MediaLightbox) over the note's media, the classic feed's way. The items come from
// the note itself (its links and imeta, noteMedia), never from the napplet, so a napplet can't make the shell load
// an address the note doesn't carry.
import { noteMedia } from "../net/note-media.js"
import { trimUrl } from "../net/vault-search.js"

const LINK = /https?:\/\/[^\s<>"]+/gi

/** A note's media as the classic feed shows it, and where `url` is in it. -> { items, start } | null. */
export function mediaViewOf(note, url) {
  if (!note || typeof note.content !== "string" || typeof url !== "string") return null
  const links = [...note.content.matchAll(LINK)].map(m => trimUrl(m[0]))
  const items = noteMedia(links, Array.isArray(note.tags) ? note.tags : [])
  const start = items.findIndex(m => m.url === url)
  return start < 0 ? null : { items, start }
}
