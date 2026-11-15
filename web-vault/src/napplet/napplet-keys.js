// The desktop's keys and hover cards over the Reader napplet (bug run, group 7). Key presses and hovers inside the
// napplet's frame never reach the page, so the Reader passes them over the bus (inc nv.key / nv.hover) and the shell
// treats them as its own: one key map (desktop/keys.js), one hover card (desktop/PeekCard.jsx). The row commands come
// back to the Reader (inc nv.key.cmd), whose rows the shell can't see. Page-level events carry them between the Reader
// pane and the desktop shell, which don't share state otherwise.
export const KEY_TOPIC = "nv.key", HOVER_TOPIC = "nv.hover", ROW_TOPIC = "nv.key.cmd"
export const NAPPLET_KEY_EVENT = "nv-napplet-key", READER_CMD_EVENT = "nv-reader-cmd", PEEK_EVENT = "nv-peek"
// Right-click over the Reader (plan step 2): the Reader passes the click (inc nv.ctx), the shell opens its own menu
// (desktop/ContextMenu.jsx) through this page event. The note open beside the list goes back as inc nv.note.open.
export const CTX_TOPIC = "nv.ctx", CTX_EVENT = "nv-napplet-ctx", OPEN_TOPIC = "nv.note.open"
/** Commands that act on a list row: the Reader's own rows when the Reader has them. */
export const ROW_CMDS = new Set(["next", "prev", "open", "reply", "like", "zap"])
const HEX = /^[0-9a-f]{64}$/

/** A key the Reader passed: only the fields keyCommand reads, as plain values; anything else is null. */
export function nappletKey(p) {
  if (!p || typeof p.key !== "string" || p.key.length > 12) return null
  return { key: p.key, metaKey: p.metaKey === true, ctrlKey: p.ctrlKey === true, altKey: p.altKey === true, typing: p.typing === true }
}

/** A hover the Reader passed, moved from the frame's coordinates to the page's (`frame`: the iframe's rect).
 *  -> { pubkey, rect } | { out: true } | null. */
export function pageHover(p, frame) {
  if (p?.out === true) return { out: true }
  const r = p?.rect
  if (!HEX.test(p?.pubkey ?? "") || !r || ![r.left, r.top, r.right, r.bottom].every(Number.isFinite) || !frame) return null
  return { pubkey: p.pubkey, rect: { left: frame.left + r.left, top: frame.top + r.top, right: frame.left + r.right, bottom: frame.top + r.bottom } }
}

/** A right-click the Reader passed, in the page's coordinates (`frame`: the iframe's rect), with a signed note
 *  (`noteOf`: reader-intents.js likedNote with the signature check) or a pubkey. -> { x, y, note } | { x, y, pubkey } | null. */
export function pageMenu(p, frame, noteOf) {
  if (!frame || !Number.isFinite(p?.x) || !Number.isFinite(p?.y)) return null
  const at = { x: frame.left + Math.max(0, Math.min(p.x, frame.width ?? p.x)), y: frame.top + Math.max(0, Math.min(p.y, frame.height ?? p.y)) }
  if (HEX.test(p.pubkey ?? "")) return { ...at, pubkey: p.pubkey }
  const note = p.event ? noteOf(p.event) : null
  return note ? { ...at, note } : null
}
