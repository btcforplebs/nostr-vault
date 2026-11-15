// What the shell hands our Your space widgets (plan NV_WEB_ONE_PLAN.md step 4): each card is a napplet that draws its
// body, and asks the shell for its data through shell-answered intents (WidgetCard.jsx). The rules stay the panels'
// own (live-now.js, on-this-day.js); this shapes their answers down to what a card draws, so nothing else crosses
// into the frame. Pure, so tests load it.
import { rowsOf, emptyLine } from "./live-now.js"
import { yearsText, lineText } from "./on-this-day.js"
import { SIZE_PX } from "./columns.js"

const HEX = /^[0-9a-f]{64}$/

/** napplet:shell/surface -> where and how big the card is drawn. size null: its own height (the card says it, below). */
export const surfaceAnswer = (size, side) => ({ surface: "widget", size: size ?? null, side })

/** A height a card reports for its own-height (Fit) mode, kept between one line and the Large size. */
export const MIN_FIT_PX = 48
export function fitHeight(h) {
  const n = Number(h)
  return Number.isFinite(n) ? Math.round(Math.min(SIZE_PX.L, Math.max(MIN_FIT_PX, n))) : null
}

/** napplet:card/count -> a whole number for the header's badge (0 hides it). */
export const countOf = c => (Number.isInteger(c) && c > 0 ? Math.min(c, 999) : 0)

/** napplet:space/livenow: streams (live-now.js liveNow) -> the rows drawn, with each host's name and picture. */
export function liveNowData(streams, profileOf, followsSomeone) {
  const { rows, more } = rowsOf(streams)
  return {
    count: streams.length, more, empty: emptyLine(followsSomeone),
    rows: rows.map(s => {
      const p = profileOf(s.host) ?? {}
      return { address: s.address, host: s.host, title: s.title || "", name: p.name || "", picture: /^https:\/\//i.test(p.picture ?? "") ? p.picture : "" }
    }),
  }
}

/** napplet:space/thisday: on-this-day.js readOnThisDay's years -> the years with notes, each note as its line only. */
export const thisDayData = years => years.filter(y => y.notes.length).map(y => ({
  label: yearsText(y.years),
  notes: y.notes.map(ev => ({ id: ev.id, text: lineText(ev), at: ev.created_at })),
}))

/** napplet:note/show { id }: only a note id (the card's own rows), never a route of the napplet's choosing. */
export const noteRoute = id => (typeof id === "string" && HEX.test(id) ? `#/thread/${id}` : null)

/** A picture the card may load (through resource): https only. */
const pic = p => (/^https:\/\//i.test(p?.picture ?? "") ? p.picture : "")
const nameOf = p => p?.display_name || p?.name || ""

/**
 * Where a card's clicks go. A card never names a route: it hands back the id of a row the shell gave it (or "globe"),
 * and the shell opens what it kept for that id (WidgetCard.jsx space/open). The footer links are the shell's own.
 * -> the route, or null.
 */
export const openRoute = (routes, id) => (typeof id === "string" && routes.has(id) ? routes.get(id) : null)

/**
 * napplet:space/vault: the Live Vault panel's rows (live-vault.js splitShown) -> what the card draws. `verbOf` is
 * VaultScreen.jsx verb, `whoOf` notify-watch.js whoText, `hrefOf` its lineHref (kept by the shell, never handed over).
 * -> { data, routes }
 */
export function vaultData({ rows, unread, faces, facesLine, fetched }, { profileOf, verbOf, whoOf, hrefOf, textOf }) {
  const routes = new Map()
  const data = {
    fetched: !!fetched, facesLine: faces.length ? facesLine : "",
    faces: faces.map(pk => ({ name: nameOf(profileOf(pk)), picture: pic(profileOf(pk)) })),
    rows: rows.map(r => {
      routes.set(r.id, hrefOf(r))
      const p = profileOf(r.actors[0])
      return { id: r.id, who: whoOf(r.actors, pk => nameOf(profileOf(pk))), verb: verbOf(r), text: textOf(r.preview ?? ""),
        at: r.created_at, unread: unread.has(r.id), name: nameOf(p), picture: pic(p) }
    }),
  }
  return { data, routes }
}

/** napplet:space/devices: my-devices.js loadMyDevices -> rows the card draws, with the header's "on the mesh" count. */
export function devicesData(loaded, now, { deviceStatus, statusLine, deviceName, header }) {
  if (!loaded) return { data: null, onMesh: 0, total: 0 }
  const rows = loaded.devices.map(d => {
    const s = deviceStatus(loaded.adverts.get(d.hex), now, { checked: loaded.checked })
    return { id: d.hex, name: deviceName(d), line: statusLine(s, now), state: s.state }
  })
  const onMesh = rows.filter(r => r.state === "online" || r.state === "connected").length
  return { data: { header, rows }, onMesh, total: rows.length }
}

/** napplet:space/messages: messages-peek.js peekRows -> the chats the card draws (the last line's preview only). A
 *  stranger's picture waits, as in the Messages list (`loadPic`: the peer is followed). */
export function messagesData({ open, note, rows }, me, { profileOf, previewOf, loadPic }) {
  const routes = new Map()
  if (!open) return { data: { status: note ? `Your messages can't be read here (${note}).` : "Reading your messages…", rows: [] }, routes }
  return {
    routes,
    data: { status: rows.length ? "" : "No messages yet.", rows: rows.map(r => {
      routes.set(r.peer, `#/dm/${r.peer}`)
      const p = profileOf(r.peer)
      return { id: r.peer, name: nameOf(p) || `${r.peer.slice(0, 8)}…`, picture: loadPic(r.peer) ? pic(p) : "", text: (r.last.from === me ? "You: " : "") + previewOf(r.last.content),
        at: r.last.at, unread: r.unread }
    }) },
  }
}

/** Globe points to two places: enough for a 112px canvas, and a smaller answer. */
const r2 = v => Math.round(v * 100) / 100
/** napplet:space/wot: the WoT mini panel's numbers, status line, new faces and globe points -> what the card draws. */
export function wotData({ counts, status, fresh, faces, points, extendedMin }, { profileOf, vouchOf }) {
  const routes = new Map([["globe", "#/wot"]])
  for (const pk of faces) routes.set(pk, `#/wot/${pk}`)
  return {
    routes,
    data: {
      counts: counts ? { everyone: counts.everyone, following: counts.following, close: counts.close } : null,
      status: status ?? "", newCount: fresh.length, extendedMin: extendedMin ?? null,
      faces: faces.map(pk => { const p = profileOf(pk); return { id: pk, name: nameOf(p) || `${pk.slice(0, 8)}…`, picture: pic(p), title: vouchOf(pk) } }),
      points: points.map(pt => ({ p: pt.p.map(r2), kind: pt.kind })),
    },
  }
}
