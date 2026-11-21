// Settings › Appearance › Translation (iPhone AppearanceSettingsView): Translate Button on Posts and Translate To
// (net/translate-prefs.js). Translate To is greyed out while the button is off, as on the phone.
import { useState } from "preact/hooks"
import { translateOn, setTranslateOn, translateTo, setTranslateTo, browserLanguage, pickerList } from "../net/translate-prefs.js"
import { supported } from "./TranslateButton.jsx"

const nameOf = code => { try { return new Intl.DisplayNames([navigator.language], { type: "language" }).of(code) || code } catch { return code } }

export const TRANSLATION_NOTE = "Posts in other languages get a Translate button. Translation runs in this browser with its own translator, and nothing is sent anywhere. The first time, your browser downloads the language."
export const NO_TRANSLATOR_NOTE = "This browser has no built-in translator, so posts show no Translate button here. Chrome 138 or later on a computer has one."

export function TranslationSettings() {
  const [on, setOn] = useState(() => translateOn())
  const [to, setTo] = useState(() => translateTo())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Translate Button on Posts</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => setOn(setTranslateOn(e.currentTarget.checked))} />
      </label>
      <label class="settings-row static">
        <span class="settings-title">Translate To</span>
        <select class="settings-select" value={to} disabled={!on} onChange={e => setTo(setTranslateTo(e.currentTarget.value))}>
          <option value="">{`Browser Language (${nameOf(browserLanguage())})`}</option>
          {pickerList().map(c => <option key={c} value={c}>{nameOf(c)}</option>)}
        </select>
      </label>
      <p class="settings-note muted small">{supported() ? TRANSLATION_NOTE : NO_TRANSLATOR_NOTE}</p>
    </>
  )
}
