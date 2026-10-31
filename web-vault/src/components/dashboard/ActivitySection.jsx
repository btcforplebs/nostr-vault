// Relay activity (RelayActivityViews: RelayActivityCard and RelayActivityWindow): the health pill, the last three
// items, and View All: a banner, Everything / Needs attention, Copy and Export report, and the full logs.
import { useState } from "preact/hooks"
import { HEALTH, bannerDetail, health, report } from "../../net/relay-activity.js"
import { saveFile } from "../../net/save-file.js"

export const SHOWN_ITEMS = 3
const time = at => new Date(at).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })

const Empty = () => (
  <div class="dash-act-empty"><b>Nothing to report yet</b><span>Vault activity and any problems will show up here.</span></div>
)
const Item = ({ item }) => (
  <div class={`dash-act-item ${item.level}`}><i aria-hidden="true" /><span>{item.text}</span><time>{time(item.at)}</time></div>
)
const Header = ({ h, children }) => (
  <div class="dash-act-head"><span>RELAY ACTIVITY</span><span class={`dash-pill ${h}`}>{HEALTH[h].pill}</span><span class="dash-spacer" />{children}</div>
)

export function ActivitySection({ items, onViewAll }) {
  const h = health(items)
  return (
    <section class="dash-section dash-activity" aria-label="Vault activity">
      <div class="dash-card">
        <Header h={h}><button type="button" class="dash-link" onClick={onViewAll}>View All</button></Header>
        {items.length ? items.slice(-SHOWN_ITEMS).map((it, i) => <Item key={i} item={it} />) : <Empty />}
      </div>
    </section>
  )
}

/** The full activity, in the sheet in place of the dashboard (RelayActivityWindow). */
export function ActivityWindow({ items, version = "" }) {
  const [filter, setFilter] = useState("all")
  const [copied, setCopied] = useState(false)
  const h = health(items)
  const shown = (filter === "attention" ? items.filter(i => i.level !== "good") : items).slice().reverse()
  const text = () => report(items, { version })
  const copy = async () => { await navigator.clipboard?.writeText(text()).catch(() => {}); setCopied(true); setTimeout(() => setCopied(false), 1500) }
  const exportReport = () => saveFile(new Blob([text()], { type: "text/plain" }), `nostrvault-relay-report-${new Date().toISOString().slice(0, 10)}.txt`).catch(() => {})
  return (
    <div class="dash-window">
      <div class={`dash-banner ${h}`}><b>{HEALTH[h].banner}</b><span>{bannerDetail(items)}</span></div>
      <div class="segmented" role="tablist" aria-label="Show">
        <button role="tab" aria-selected={filter === "all"} class={filter === "all" ? "on" : ""} onClick={() => setFilter("all")}>Everything</button>
        <button role="tab" aria-selected={filter === "attention"} class={filter === "attention" ? "on" : ""} onClick={() => setFilter("attention")}>Needs attention</button>
      </div>
      <div class="dash-card">
        {shown.length ? shown.map((it, i) => <Item key={i} item={it} />) : filter === "attention" ? <div class="dash-act-empty"><b>Nothing needs attention</b></div> : <Empty />}
      </div>
      <div class="dash-actions">
        <button type="button" class="dash-button" disabled={!items.length} onClick={copy}>{copied ? "Copied" : "Copy"}</button>
        <button type="button" class="dash-button" disabled={!items.length} onClick={exportReport}>Export report</button>
      </div>
      <p class="muted small">Copies leave out keys, IDs, IP addresses and file paths.</p>
      <a class="dash-link" href="#/settings/logs">Open full logs</a>
    </div>
  )
}
