// Settings › Feed › Web of Trust › "Show 'Outside your web' under posts" (RESEARCH/NV_ONE_WOT_GATE.md 2b, call 6;
// default on). Off: a post's replies, quotes, likes and zaps show no outside row at all, and a feed's folded "Outside
// your web" section is gone too. Nothing is deleted: Vault › ··· › Outside still lists them. Search you typed and
// Notifications are not "under a post", so they keep their fold. Kept in this browser. iPhone/Mac twin:
// HavenConfig.showsOutsideUnderPosts.
const KEY = "nv-outside-under-posts"
const listeners = new Set()

export const showsOutside = (storage = globalThis.localStorage) => { try { return storage?.getItem(KEY) !== "off" } catch { return true } }
export function setShowsOutside(on, storage = globalThis.localStorage) {
  try { storage?.setItem(KEY, on ? "on" : "off") } catch {}
  for (const cb of listeners) { try { cb() } catch {} }
}
/** cb() whenever the switch moves. -> unsubscribe. */
export const onShowsOutside = cb => { listeners.add(cb); return () => listeners.delete(cb) }

/**
 * A zap row the gate judged outside (call 4): the amount stays, the comment and the face fold. -> the row with
 * `who` null and no comment, so it draws as a zap naming nobody.
 */
export const foldedZap = row => ({ ...row, who: null, text: "", comment: "" })

/** Notification rows with the words of every zap whose sender `inside(pk)` says is outside your web taken off; the
 *  row, its sats and its sender stay (a zap is about you). */
export const zapWords = (rows, inside) => rows.map(r => (r.type === "zap" && r.comment && !inside(r.who?.[0]) ? { ...r, comment: "" } : r))
