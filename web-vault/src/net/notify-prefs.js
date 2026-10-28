// Which kinds of browser notification the user wants (the iPhone's Settings › Notifications, NotificationPolicy):
// mentions, replies, messages, zaps and follows on; likes and reposts off until turned on. Kept in this browser.
// The master switch is notify-watch.js notifyOn; these only matter while it is on.

export const TYPES = [
  { id: "mentions", title: "Mentions and quotes", on: true },
  { id: "replies", title: "Replies", on: true },
  { id: "dms", title: "Messages", on: true },
  { id: "zaps", title: "Zaps", on: true },
  { id: "follows", title: "New followers", on: true },
  { id: "reactions", title: "Likes and reactions", on: false },
  { id: "reposts", title: "Reposts", on: false },
]

const KEY = "nv-notify-types"
const listeners = new Set()

/** { [type]: boolean }, the defaults filled in for anything not set. */
export function readTypes(storage = globalThis.localStorage) {
  let saved = {}
  try { const v = JSON.parse(storage?.getItem(KEY) ?? "{}"); if (v && typeof v === "object") saved = v } catch {}
  return Object.fromEntries(TYPES.map(t => [t.id, typeof saved[t.id] === "boolean" ? saved[t.id] : t.on]))
}

export function setType(id, on, storage = globalThis.localStorage) {
  const next = { ...readTypes(storage), [id]: !!on }
  try { storage?.setItem(KEY, JSON.stringify(next)) } catch {}
  for (const cb of listeners) cb()
  return next
}
export const onTypes = cb => { listeners.add(cb); return () => listeners.delete(cb) }

/** The switch a Vault line's kind answers to (LocalNotificationService's types). Articles and highlights raise none,
 *  as on the phone. */
const OF_LINE = { reply: "replies", mention: "mentions", quote: "mentions", zap: "zaps", follow: "follows", like: "reactions", repost: "reposts" }
export const typeOfLine = kind => OF_LINE[kind] ?? null

/** Whether a Vault line of `kind` raises a notification under `types` (readTypes). */
export const lineWanted = (kind, types = readTypes()) => !!types[typeOfLine(kind)]
