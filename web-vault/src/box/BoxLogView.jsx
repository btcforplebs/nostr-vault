// The box's full log in the dashboard sheet (Activity › View All › Open full logs, box mode): the engine's and
// havend's own lines from GET /api/box/logs, newest last, unredacted (only the box's first account may read them).
// `state`: the logs call's { value } | { error }; useBoxDashboard asks again every 30 s, so there is no Refresh.
import { useState } from "preact/hooks"
import { lineText } from "./box-activity.js"

const time = at => new Date(at * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit" })

export function BoxLogView({ state }) {
  const [copied, setCopied] = useState(false)
  const lines = (state?.value?.lines ?? []).map(l => ({ ...l, text: lineText(l.text) })).filter(l => l.text)
  const text = () => lines.map(l => `${new Date(l.at * 1000).toISOString()} ${l.source} ${l.text}`).join("\n")
  const copy = async () => { await navigator.clipboard?.writeText(text()).catch(() => {}); setCopied(true); setTimeout(() => setCopied(false), 1500) }
  return (
    <div class="dash-window">
      {!state ? <p class="muted small">Asking your box…</p>
        : state.error ? <p class="error small" role="alert">{state.error}</p>
        : <div class="dash-card dash-log" role="log" aria-label="Box log">
          {lines.length ? lines.map(l => <div key={l.seq}><time>{time(l.at)}</time><b>{l.source}</b>{l.text}</div>) : <span class="muted">Nothing in the box's log yet.</span>}
        </div>}
      <div class="dash-actions">
        <button type="button" class="dash-button" disabled={!lines.length} onClick={copy}>{copied ? "Copied" : "Copy"}</button>
      </div>
      <p class="muted small">The box keeps its newest 2,000 lines while it runs. Only the box's first account can read them.</p>
    </div>
  )
}
