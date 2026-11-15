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
