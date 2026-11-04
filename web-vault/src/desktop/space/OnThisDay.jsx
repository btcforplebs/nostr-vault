// On this day: a "Your space" panel (Logen, 2026-11-04). The user's own notes from today's date one and two years ago,
// read from their own vault (on-this-day.js), never from a relay. A click opens the note in the left column
// (#/thread/<id>). One quiet line when there is nothing. It reads again when the day changes, and publishes nothing.
import { useEffect, useState } from "preact/hooks"
import { readOnThisDay, dayKey, yearsText, lineText } from "./on-this-day.js"
import { Icon } from "../Sidebar.jsx"
import "../../styles/on-this-day.css"

/** A clock face: the panel's icon. */
const CLOCK = "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2"
const DAY_CHECK_MS = 60_000

export function OnThisDay({ ctx, open = true, tools = null }) {
  const me = ctx.session.pubkey
  const [day, setDay] = useState(() => dayKey())
  const [years, setYears] = useState(null)
  useEffect(() => {
    const t = setInterval(() => setDay(dayKey()), DAY_CHECK_MS)
    return () => clearInterval(t)
  }, [])
  useEffect(() => {
    let live = true
    setYears(null)
    readOnThisDay(ctx.vault, me).then(y => { if (live) setYears(y) }).catch(() => { if (live) setYears([]) })
    return () => { live = false }
  }, [me, day])
  const any = years?.some(y => y.notes.length)
  return (
    <section class={open ? "sp-panel on-this-day" : "sp-panel on-this-day closed"} aria-label="On this day">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={CLOCK} size={15} /></span>
        <h3>On this day</h3>
        {tools}
      </header>
      <ul class="sp-rows">
        {!years ? <li class="sp-empty">Reading your vault…</li>
          : !any ? <li class="sp-empty">Nothing from this day in past years.</li>
          : years.filter(y => y.notes.length).map(y => [
              <li key={`h${y.years}`} class="otd-year">{yearsText(y.years)}</li>,
              ...y.notes.map(ev => <Row key={ev.id} ev={ev} />),
            ])}
      </ul>
    </section>
  )
}

function Row({ ev }) {
  const at = new Date(ev.created_at * 1000)
  return (
    <li>
      <a class="otd-row" href={`#/thread/${ev.id}`}>
        <span class="otd-text">{lineText(ev)}</span>
        <time datetime={at.toISOString()}>{at.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time>
      </a>
    </li>
  )
}
