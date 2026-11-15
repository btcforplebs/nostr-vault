// Settings › Appearance › Mode: Dark, Light or Auto (net/appearance.js). The same segmented pill as Send Delay.
import { useState } from "preact/hooks"
import { APPEARANCE_CHOICES, APPEARANCE_LABELS, appearance, setAppearance } from "../net/appearance.js"

export function AppearanceModePicker() {
  const [mode, setMode] = useState(() => appearance())
  const pick = m => { setAppearance(m); setMode(appearance()) }
  return (
    <>
      <div class="settings-row static appearance-mode">
        <span class="settings-title" id="appearance-mode-label">Mode</span>
        <div class="seg-pill" role="radiogroup" aria-labelledby="appearance-mode-label">
          {APPEARANCE_CHOICES.map(m => (
            <button key={m} type="button" role="radio" aria-checked={mode === m} class={mode === m ? "on" : ""} onClick={() => pick(m)}>{APPEARANCE_LABELS[m]}</button>
          ))}
        </div>
      </div>
      {mode === "auto" ? <p class="settings-note muted small">Follows your device's light or dark setting.</p> : null}
    </>
  )
}
