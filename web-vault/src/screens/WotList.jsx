// The Web of Trust as a list (parity #7): the globe's people for the layer picked, as rows, over the globe. A row
// opens that person's trust card on the globe, as a tap on their face does. Pictures load for your follows; a
// stranger's waits (their host would learn your IP), as elsewhere.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { listPeople, rowLine, LIST_PAGE } from "./wot-list.js"

export function WotList({ ctx, web, layer, lit, title, onPick, onClose }) {
  const [n, setN] = useState(LIST_PAGE)
  const people = listPeople(web, layer, lit)
  const shown = people.slice(0, n)
  const key = shown.map(p => p.pk).join()
  useEffect(() => {
    if (!shown.length) return
    const strangers = shown.filter(p => p.layer !== "follow").map(p => p.pk)
    const follows = shown.filter(p => p.layer === "follow").map(p => p.pk)
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])
    if (follows.length) fetchProfiles(ctx.vault, follows, relays).catch(() => {})
    if (strangers.length) fetchProfiles(ctx.vault, strangers, relays, { save: false }).catch(() => {})
  }, [key])
  useEffect(() => { setN(LIST_PAGE) }, [layer, lit])
  return (
    <section class="wot-list" role="region" aria-label={`${title} as a list`}>
      <header class="wot-list-head">
        <b>{title} · {people.length.toLocaleString()}</b>
        <button type="button" class="small" onClick={onClose}>Globe</button>
      </header>
      {!people.length ? <p class="muted small wot-list-empty">Nobody here yet.</p> : (
        <ul class="wot-list-rows">
          {shown.map(p => (
            <li key={p.pk}>
              <button type="button" class="wot-list-row" onClick={() => onPick(p.pk)}>
                <Avatar pubkey={p.pk} size={36} load={p.layer === "follow"} />
                <span class="wot-list-text"><AuthorName pubkey={p.pk} /><span class="muted small">{rowLine(p)}</span></span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {people.length > n && <button type="button" class="more" onClick={() => setN(n + LIST_PAGE)}>Show more ({(people.length - n).toLocaleString()} left)</button>}
    </section>
  )
}
