// The short tour a new account sees once, after it's in (net/first-run.js TOUR). Next, then Done; either way it's
// marked done for the account and never shows again. The notification question waits until it's closed.
import { useState } from "preact/hooks"
import { TOUR } from "../net/first-run.js"
import "../styles/first-run.css"

export function WelcomeTour({ onDone }) {
  const [i, setI] = useState(0)
  const card = TOUR[i], last = i === TOUR.length - 1
  return (
    <div class="tour" role="dialog" aria-modal="true" aria-labelledby="tour-title">
      <div class="tour-card">
        <p class="tour-step muted small">{i + 1} of {TOUR.length}</p>
        <h2 id="tour-title">{card.title}</h2>
        <p>{card.body}</p>
        <div class="tour-actions">
          <button type="button" class="tour-skip" onClick={onDone}>Skip</button>
          <button type="button" class="primary" autofocus onClick={() => (last ? onDone() : setI(i + 1))}>{last ? "Done" : "Next"}</button>
        </div>
      </div>
    </div>
  )
}
