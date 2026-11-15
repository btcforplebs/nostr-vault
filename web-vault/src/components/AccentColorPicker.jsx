// Settings › Appearance › Accent (net/accent.js): eight ready-made colours, orange first, then a wheel for any colour
// (the browser's own picker; on an iPhone it's Apple's colour wheel). Under it, the colour as it shows in dark and
// in light mode, drawn by the real tokens, so what you see here is what the app does.
import { useState } from "preact/hooks"
import { ACCENT_PRESETS, accent, setAccent } from "../net/accent.js"

function Preview({ mode }) {
  return (
    <div class="accent-preview" data-theme={mode}>
      <span class="accent-preview-mode">{mode === "dark" ? "Dark" : "Light"}</span>
      <span class="accent-preview-link">#nostr</span>
      <span class="accent-preview-fill">Follow</span>
    </div>
  )
}

export function AccentColorPicker() {
  const [hex, setHex] = useState(() => accent())
  const pick = h => { setAccent(h); setHex(accent()) }
  const custom = !ACCENT_PRESETS.some(p => p.hex === hex)
  return (
    <>
      <div class="settings-row static accent-row" role="radiogroup" aria-label="Accent colour">
        {ACCENT_PRESETS.map(p => (
          <button key={p.hex} type="button" role="radio" aria-checked={hex === p.hex} aria-label={p.name} title={p.name}
            class={hex === p.hex ? "accent-dot on" : "accent-dot"} style={`--dot: ${p.hex}`} onClick={() => pick(p.hex)} />
        ))}
        <label class={custom ? "accent-dot accent-custom on" : "accent-dot accent-custom"} title="Any colour" style={custom ? `--dot: ${hex}` : undefined}>
          <input type="color" value={hex} aria-label="Any colour" onInput={e => pick(e.currentTarget.value)} />
        </label>
      </div>
      <div class="accent-previews" aria-hidden="true"><Preview mode="dark" /><Preview mode="light" /></div>
      <p class="settings-note muted small">The last circle opens a colour wheel. In light mode a pale colour is shown a little deeper so text stays readable.</p>
    </>
  )
}
