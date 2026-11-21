// The building blocks every Box screen section shares: a titled part that says "Asking the box…" or the box's error
// until its call answers, a label/value row (with Copy), and a used-of-total meter.
import { useState } from "preact/hooks"
import { bytes, share } from "../format.js"

export function Part({ title, state, children }) {
  return (
    <section class="settings-group">
      <div class="section-label">{title}</div>
      {!state ? <p class="muted small box-pad">Asking the box…</p>
        : state.error ? <p class="error small box-pad" role="alert">{state.error}</p>
        : children}
    </section>
  )
}

export function Row({ label, value, tone = "", copy }) {
  const [copied, setCopied] = useState(false)
  return (
    <div class="settings-row box-row">
      <span class="settings-title">{label}</span>
      <span class={`box-value ${tone}`}>{value}</span>
      {copy && <button type="button" class="small" onClick={() => navigator.clipboard?.writeText(copy).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1200) })}>{copied ? "Copied" : "Copy"}</button>}
    </div>
  )
}

export function Meter({ label, used, total }) {
  const s = share(used, total)
  return (
    <div class="settings-row box-row box-meter-row">
      <span class="settings-title">{label}</span>
      <span class="box-value">{bytes(used)} of {bytes(total)}</span>
      <span class="box-meter" role="meter" aria-label={label} aria-valuemin="0" aria-valuemax="100" aria-valuenow={s == null ? undefined : Math.round(s * 100)}>
        <span style={{ width: s == null ? 0 : `${Math.round(s * 100)}%` }} class={s != null && s > 0.9 ? "full" : ""} />
      </span>
    </div>
  )
}
