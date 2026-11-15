// The desktop's keys and hover cards over the Reader napplet (bug run, group 7). Key presses and hovers inside the
// napplet's frame never reach the page, so the Reader passes them over the bus (inc nv.key / nv.hover) and the shell
// treats them as its own: one key map (desktop/keys.js), one hover card (desktop/PeekCard.jsx). The row commands come
// back to the Reader (inc nv.key.cmd), whose rows the shell can't see. Page-level events carry them between the Reader
// pane and the desktop shell, which don't share state otherwise.
export const KEY_TOPIC = "nv.key", HOVER_TOPIC = "nv.hover", ROW_TOPIC = "nv.key.cmd"
export const NAPPLET_KEY_EVENT = "nv-napplet-key", READER_CMD_EVENT = "nv-reader-cmd", PEEK_EVENT = "nv-peek"
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
