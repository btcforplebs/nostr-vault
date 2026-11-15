// Notifications in the Reader (plan NV_WEB_ONE_PLAN.md step 6b): the shell reads them with the screen's own rules
// (screens/useNotifications.js: grouping, the outside fold, blocks, zap receipts checked, the visit's unread mark),
// and hands the Reader each row as it draws it, as plain strings. A click hands back the row's id; the shell opens
// what it kept for it (the screen's rowHref), never a route the frame names. Older pages come when the Reader asks.
//   napplet:notifications/list { filter: "all" | "mentions" } -> { data }   (notifAnswer)
//   napplet:notifications/more {}                             -> asks for the next older page
//   napplet:notifications/open { id }                         -> opens a row it handed out
// A change comes to the Reader as inc nv.notifications.changed. The Reader's only.
import { READER_DTAG as READER } from "./first-party-list.js"
import { filterRows } from "../net/notifications.js"
import { outsideCount } from "../net/outside-fold.js"

export const NOTIF_TOPIC = "nv.notifications.changed"
export const MAX_FACES = 6
const https = v => (/^https:\/\//i.test(v ?? "") ? String(v).slice(0, 2048) : "")
const nameOf = p => String(p?.display_name || p?.name || "").slice(0, 80)

/**
 * One row (net/notifications.js groupNotifications) -> what the Reader draws. `h`: { me, notes, unreadSince, known,
 * profileOf, verbOf, whoOf, aboutOf, aboutYourPost }. A stranger's picture is left out (known: a follow or you).
 */
export function shapeRow(row, h) {
  const ev = row.events?.[0]
  const words = ["reply", "mention", "quote", "highlight"].includes(row.type) ? String(ev?.content ?? "")
    : (row.type === "zap" || row.type === "article") && row.comment ? String(row.comment) : ""
  const note = row.noteId ? h.notes.get(row.noteId) : undefined
  let about = null
  if (!words && h.aboutYourPost(row) && note && note.pubkey === h.me) {
    const { parts, images } = h.aboutOf(note)
    const text = parts.map(p => (typeof p === "string" ? p : `@${nameOf(h.profileOf(p.pubkey)) || "someone"}`)).join(" ")
    const pics = images.map(https).filter(Boolean)
    if (text || pics.length) about = { text: text.slice(0, 400), thumbs: pics.slice(0, 3), more: Math.max(0, pics.length - 3) }
  }
  const who = h.whoOf(row.who, pk => nameOf(h.profileOf(pk)))
  return {
    id: row.id, type: row.type, who, verb: h.verbOf(row), at: row.created_at, unread: row.created_at > h.unreadSince,
    faces: row.who.slice(0, MAX_FACES).map(pk => { const p = h.profileOf(pk); return { name: nameOf(p), picture: h.known(pk) ? https(p?.picture) : "" } }),
    text: words.slice(0, 2000), about,
  }
}

/** The list for one filter, and the routes its rows open (kept by the shell). `list`: useNotifications' result for "all". */
export function notifAnswer(list, filter, h, hrefOf) {
  const routes = new Map()
  const shape = r => { const href = hrefOf(r); if (href) routes.set(r.id, href); return { ...shapeRow(r, h), open: !!href } }
  const shown = list.shown === null ? null : filterRows(list.shown, filter)
  const outside = filter === "all" && list.outside ? list.outside : []
  return {
    routes,
    data: {
      filter, status: String(list.status ?? ""), loading: !!list.loading && !(shown?.length), done: !!list.more?.done || list.more?.until === null,
      busy: !!list.more?.busy, rows: shown ? shown.map(shape) : null, outside: outside.map(r => ({ ...shape(r), unread: false })), outsideCount: outsideCount(outside),
    },
  }
}

/** `answer(filter)` -> { data, routes }; `more()`; `open(hash)`. -> off() */
export function notifIntents({ bus, answer, more, open }) {
  let routes = new Map()
  const reader = (action, run) => bus.register({ id: `shell-notifications-${action}`, title: "Notifications", archetype: "notifications", actions: [action], conventions: [], deliver: (p, from) =>
    (from?.dTag !== READER ? { ok: false, error: "the Reader's only" } : run(p ?? {})) })
  const offs = [
    reader("list", p => {
      const a = answer(p.filter === "mentions" ? "mentions" : "all")
      if (!a) return { ok: true, data: null }
      for (const [k, v] of a.routes) routes.set(k, v)
      return { ok: true, data: a.data }
    }),
    reader("more", () => { more(); return { ok: true } }),
    reader("open", p => {
      const to = typeof p.id === "string" && routes.has(p.id) ? routes.get(p.id) : null
      if (!to) return { ok: false, error: "not a row this list shows" }
      open(to)
      return { ok: true }
    }),
  ]
  return () => offs.forEach(off => off())
}
