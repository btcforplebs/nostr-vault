// Settings › Feed Text (iPhone AppearanceSettingsView's two line-limit steppers): Compact View and Threaded View, each
// with − and + inside 1-12 lines. Read by the feed as it draws (FeedRows, FeedThreadCard), so a change shows on the
// next visit to the Feed.
import { useState } from "preact/hooks"
import { LINE_LIMITS, MIN_LINES, MAX_LINES, lineLimit, setLineLimit, linesText } from "../net/line-limits.js"

export function LineLimitSteppers() {
  return (
    <>
      <Stepper view="compact" />
      <Stepper view="threaded" />
      <p class="settings-note muted small">Lines of text each post shows before it is cut off. In Threaded View, replies show one line fewer.</p>
    </>
  )
}

function Stepper({ view }) {
  const [n, setN] = useState(() => lineLimit(view))
  const { title } = LINE_LIMITS[view]
  const step = d => { setLineLimit(view, n + d); setN(lineLimit(view)) }
  return (
    <div class="settings-row static line-stepper">
      <span class="settings-title">{title}</span>
      <span class="muted line-stepper-value" aria-live="polite">{linesText(n)}</span>
      <span class="seg-pill" role="group" aria-label={`${title} lines`}>
        <button type="button" aria-label={`Fewer lines in ${title}`} disabled={n <= MIN_LINES} onClick={() => step(-1)}>−</button>
        <button type="button" aria-label={`More lines in ${title}`} disabled={n >= MAX_LINES} onClick={() => step(1)}>+</button>
      </span>
    </div>
  )
}
