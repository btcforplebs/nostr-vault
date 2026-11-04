// Who zapped a note, as on the iPhone (ZappersListView): each zapper's name, sats and comment, biggest first. Opened
// from a note's zap total. Only a follow's (or your own) picture loads: a stranger's would tell their host your IP.
// Blocked people are left out, and zaps from outside your web of trust (net/web-trust.js) show as one total line, so
// a stranger's comment isn't read out here.
import { useEffect, useRef } from "preact/hooks"
import { useBlocks } from "./useBlocks.js"
import { useWebTrust } from "./useWebTrust.js"
import { Avatar } from "./Avatar.jsx"
import { AuthorName } from "./NoteCard.jsx"
import { formatSats } from "../net/notifications.js"
import { zappersOf } from "../net/zaps.js"

export function ZappersList({ ctx, noteId, trusted = () => false, onClose, onPerson }) {
  const { blocked } = useBlocks(ctx)
  const web = useWebTrust(ctx)
  const all = zappersOf(noteId).filter(z => !blocked.has(z.sender))
  const zaps = all.filter(z => web.inside(z.sender))
  const outside = all.filter(z => !web.inside(z.sender))
  const outsideSats = outside.reduce((n, z) => n + z.sats, 0)
  const box = useRef(null)
  useEffect(() => { box.current?.querySelector("button")?.focus() }, [])
  // Clicks inside stay here: the card under it opens its thread on a click.
  return (
    <div class="zap-picker zappers" role="dialog" aria-label="Zaps" ref={box} onClick={e => e.stopPropagation()}
      onKeyDown={e => { if (e.key === "Escape") onClose() }}>
      <div class="zap-picker-row" style="justify-content: space-between; align-items: center">
        <strong>Zaps</strong><button type="button" class="small" onClick={onClose}>Close</button>
      </div>
      {!all.length
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
      {outside.length > 0 && <p class="muted small" style="margin: 0">
        {outside.length} {outside.length === 1 ? "zap" : "zaps"} from outside your web · {formatSats(outsideSats)} sats</p>}
    </div>
  )
}
