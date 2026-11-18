// Settings › Feed › Reach (RESEARCH/NV_ONE_WOT_GATE.md 2b): per feed, how far past your web it reaches. "Your web" is
// your follows and the people at least 10 of them follow; "+ a few one hop out" adds a ration of people fewer of
// your follows follow (at most one a person, never replies; net/web-gate.js capHop3). Global on Everyone ignores it.
import { useState } from "preact/hooks"
import { REACH_FEEDS, loadReach, saveReach } from "../../net/feed-gate.js"
import { Section } from "./Section.jsx"

export const REACH_NOTE = "Notes from outside your reach fold under \"Outside your web\" at the end of the feed. Global on Everyone shows everyone."
const SHORT = { web: "Your web", webAndHop3: "+ a few one hop out" }

export function FeedReachSection() {
  const [reach, setReach] = useState(() => Object.fromEntries(REACH_FEEDS.map(([id]) => [id, loadReach(id)])))
  const pick = (id, r) => { saveReach(id, r); setReach(all => ({ ...all, [id]: loadReach(id) })) }
  return (
    <Section label="Reach" note={REACH_NOTE}>
      {REACH_FEEDS.map(([id, label]) => (
        <div key={id} class="settings-row static feed-reach">
          <span class="settings-title" id={`reach-${id}`}>{label}</span>
          <div class="seg-pill" role="radiogroup" aria-labelledby={`reach-${id}`}>
            {["web", "webAndHop3"].map(r => (
              <button key={r} type="button" role="radio" aria-checked={reach[id] === r} class={reach[id] === r ? "on" : ""} onClick={() => pick(id, r)}>{SHORT[r]}</button>
            ))}
          </div>
        </div>
      ))}
    </Section>
  )
}
