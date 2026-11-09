// Message notifications while the tab is open: "New message" from X. The text itself never goes in one: the
// browser keeps it in the system notification centre (and on the lock screen) after the tab closes. The messages are the ones Messages
// opens (dms.js, decrypted by the user's signer, held in memory only); this picks which new ones to show. Requests
// (strangers, dm-trust.js) and blocked people never raise one, as they never raise the badge.

const MARK = "nv-notify-dm-mark"
export const DM_AT_ONCE = 3

/** The newest message time already raised; the first time, now, so the messages a first load opens never pop up. */
export function readDmMark(me, { storage = globalThis.localStorage, now = Math.floor(Date.now() / 1000) } = {}) {
  let v = 0
  try { v = Number(storage?.getItem(`${MARK}:${me}`)) || 0 } catch {}
  if (v > 0) return v
  writeDmMark(me, now, storage)
  return now
}
export function writeDmMark(me, at, storage = globalThis.localStorage) {
  try { storage?.setItem(`${MARK}:${me}`, String(at)) } catch {}
}

/**
 * Which messages to raise: sent to the user (not by them) after `mark`, not from `hidden` (blocked people and
 * Requests, dm-trust.js hiddenFromUnread), and not in the conversation on screen (`onScreen`, a peer). Newest first,
 * DM_AT_ONCE at most, else one summary. Every message moves the mark, shown or not; one dated ahead of `now` can't
 * hold it there. -> { notices: [{ title, body, tag, href }], mark }
 */
export function dmNotices(messages, me, { mark, hidden = new Set(), onScreen = null, nameOf = () => "", now = Math.floor(Date.now() / 1000) } = {}) {
  const incoming = [...messages.values()].filter(m => m && m.from !== me && !m.pending && Number.isFinite(m.at) && m.at > mark)
  const next = Math.max(mark, Math.min(now, incoming.reduce((a, m) => Math.max(a, m.at), mark)))
  const fresh = incoming.filter(m => !hidden.has(m.peer) && m.peer !== onScreen).sort((a, b) => b.at - a.at)
  if (!fresh.length) return { notices: [], mark: next }
  const who = pk => nameOf(pk) || "Someone"
  if (fresh.length > DM_AT_ONCE) {
    const peers = new Set(fresh.map(m => m.peer))
    return { notices: [{ title: `${fresh.length} new messages`, body: `From ${who(fresh[0].peer)}${peers.size > 1 ? ` and ${peers.size - 1} more` : ""}`, tag: "nv:dm-summary", href: "#/messages" }], mark: next }
  }
  return { notices: fresh.map(m => ({ title: "New message", body: `From ${who(m.peer)}`, tag: `nv:dm:${m.id}`, href: `#/dm/${m.peer}` })), mark: next }
}

/** The conversation the user is looking at now, or null. */
// The phone's address is #/dm/<hex>; the desktop's is the Messages list with ?dm=<hex> (desktop/routes.js deskRedirect).
export const dmOnScreen = (doc = globalThis.document, hash = globalThis.location?.hash ?? "") =>
  doc?.visibilityState === "visible" ? (/^#\/?dm\/([0-9a-f]{64})/.exec(hash)?.[1] ?? /^#\/?messages(?:\/[^?]*)?\?(?:.*&)?dm=([0-9a-f]{64})(?:&|$)/.exec(hash)?.[1] ?? null) : null
