// The Vault Dashboard's building blocks (iPhone VaultDashboardComponents.swift): a titled card, rows with an icon, a
// title, a detail line and a done / to-do / info state, buttons at the end of a row, and rows that open a breakdown.
import { useState } from "preact/hooks"

const path = d => <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

export const ICONS = {
  key: "M15 7a4 4 0 1 1-4 4l-7 7v3h3v-2h2v-2h2l1-1a4 4 0 0 1 3-9z",
  people: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM22 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8",
  zip: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M10 9h1M10 12h1M10 15h1",
  crowd: "M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM23 21v-2a4 4 0 0 0-3-3.9",
  hand: "M18 11V6a2 2 0 0 0-4 0v5M14 10V4a2 2 0 0 0-4 0v6M10 10.5V6a2 2 0 0 0-4 0v8a8 8 0 0 0 16 0v-2a2 2 0 0 0-4 0",
  note: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h8",
  article: "M4 4h16v16H4zM8 8h8M8 12h8M8 16h5",
  highlight: "M9 11l-6 6v3h9l3-3M22 12l-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4",
  heart: "M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z",
  bolt: "M13 2L3 14h9l-1 8 10-12h-9z",
  envelope: "M4 4h16v16H4zM4 6l8 7 8-7",
  person: "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
  more: "M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM19 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM5 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2z",
  photo: "M3 5h18v14H3zM8.5 10a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3zM21 15l-5-5L5 19",
  down: "M12 3v12M7 10l5 5 5-5M4 21h16",
  stack: "M3 7h18v12H3zM6 4h12",
  up: "M12 21V9M7 14l5-5 5 5M4 3h16",
  antenna: "M5 12a7 7 0 0 1 14 0M8.5 12a3.5 3.5 0 0 1 7 0M12 12v9",
  shield: "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10zM9 12l2 2 4-4",
  server: "M4 4h16v6H4zM4 14h16v6H4zM8 7h.01M8 17h.01",
  check: "M20 6L9 17l-5-5",
}
export const Icon = ({ name }) => path(ICONS[name] ?? ICONS.more)

/** A titled card (DashboardSection). `detail` sits at the right of the title. */
export function Section({ title, detail, children, label }) {
  return (
    <section class="dash-section" aria-label={label ?? title}>
      <div class="dash-head"><h3>{title}</h3>{detail && <span class="dash-detail">{detail}</span>}</div>
      <div class="dash-card">{children}</div>
    </section>
  )
}

/** The row's leading icon: a green check when done, an orange "!" to do, else the row's own icon (RowIcon). */
export function RowIcon({ icon, state = "info" }) {
  return (
    <span class={`dash-icon ${state}`} aria-hidden="true">
      {state === "done" ? path(ICONS.check) : state === "todo" ? <b>!</b> : <Icon name={icon} />}
    </span>
  )
}

/** A row (DashboardRow / DashboardRowLink). With `href` the whole row is a link and a to-do row says "Fix"; `children`
 *  sit at the end (a RowButton). `progress` (0-1) draws a bar under the detail. */
export function Row({ icon, title, detail, state = "info", href, children, progress }) {
  const body = (
    <>
      <RowIcon icon={icon} state={state} />
      <span class="dash-text">
        <span class="dash-title">{title}</span>
        {detail && <span class="dash-sub">{detail}</span>}
        {progress != null && <progress class="dash-progress" max="1" value={progress} />}
      </span>
      {children}
      {href && state === "todo" && <span class="dash-fix">Fix</span>}
      {href && <Chevron />}
    </>
  )
  return href ? <a class="dash-row link" href={href}>{body}</a> : <div class="dash-row">{body}</div>
}

/** A settings row: icon, title, its value and a chevron (SettingLink). */
export function SettingRow({ icon, title, value, href }) {
  return (
    <a class="dash-row link" href={href}>
      <RowIcon icon={icon} />
      <span class="dash-text"><span class="dash-title">{title}</span></span>
      {value != null && <span class="dash-value">{value}</span>}
      <Chevron />
    </a>
  )
}

export const Chevron = ({ open = false }) => <svg class={`dash-chevron${open ? " open" : ""}`} viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>

/** The small button at a row's end (RowButton). */
export const RowButton = ({ title, busy = false, disabled = false, onClick }) =>
  <button type="button" class="dash-button small" disabled={disabled || busy} aria-busy={busy || undefined} onClick={onClick}>{busy ? "…" : title}</button>

/** A row that opens its breakdown underneath it (ExpandingRow). */
export function ExpandingRow({ icon, title, value, detail, canExpand = true, children }) {
  const [open, setOpen] = useState(false)
  const label = (
    <>
      <RowIcon icon={icon} />
      <span class="dash-text"><span class="dash-title">{title}</span>{detail && <span class="dash-sub">{detail}</span>}</span>
      <span class="dash-value">{value}</span>
      <span style={{ visibility: canExpand ? "visible" : "hidden" }}><Chevron open={open} /></span>
    </>
  )
  return (
    <div class="dash-expand">
      {canExpand
        ? <button type="button" class="dash-row link" aria-expanded={open} onClick={() => setOpen(o => !o)}>{label}</button>
        : <div class="dash-row">{label}</div>}
      {open && canExpand && <div class="dash-breakdown">{children}</div>}
    </div>
  )
}

/** One line of a breakdown: a name and its number (BreakdownLine). */
export const Line = ({ title, value }) => <div class="dash-line"><span>{title}</span><span>{value}</span></div>
