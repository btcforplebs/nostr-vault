// Who zapped a note, as on the iPhone (ZappersListView): each zapper's name, sats and comment, biggest first. Opened
// from a note's zap total. Only a follow's (or your own) picture loads: a stranger's would tell their host your IP.
import { useEffect, useRef } from "preact/hooks"
import { Avatar } from "./Avatar.jsx"
import { AuthorName } from "./NoteCard.jsx"
import { formatSats } from "../net/notifications.js"
import { zappersOf } from "../net/zaps.js"

export function ZappersList({ noteId, trusted = () => false, onClose, onPerson }) {
  const zaps = zappersOf(noteId)
  const box = useRef(null)
  useEffect(() => { box.current?.querySelector("button")?.focus() }, [])
  // Clicks inside stay here: the card under it opens its thread on a click.
  return (
    <div class="zap-picker zappers" role="dialog" aria-label="Zaps" ref={box} onClick={e => e.stopPropagation()}
      onKeyDown={e => { if (e.key === "Escape") onClose() }}>
      <div class="zap-picker-row" style="justify-content: space-between; align-items: center">
        <strong>Zaps</strong><button type="button" class="small" onClick={onClose}>Close</button>
      </div>
      {!zaps.length
        ? <p class="muted small" style="margin: 0">Nobody's zap here could be checked yet.</p>
        : <ul class="zappers-list">{zaps.map(z => (
          <li key={z.id}>
            <button type="button" class="zapper" onClick={() => onPerson?.(z.sender)}>
              <Avatar pubkey={z.sender} size={32} load={trusted(z.sender)} />
              <span class="zapper-main">
                <span class="zapper-head"><AuthorName pubkey={z.sender} /><span class="zapper-sats">{formatSats(z.sats)} sats</span></span>
                {z.comment && <span class="muted small zapper-comment">{z.comment}</span>}
              </span>
            </button>
          </li>))}
        </ul>}
    </div>
  )
}
