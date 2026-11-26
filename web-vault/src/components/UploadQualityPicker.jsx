// Settings › Media & Cache › Upload Quality: Standard or Original for photos in notes, live chat and messages
// (net/upload-quality.js). The same segmented picker as Send Delay (SendDelayPicker.jsx). No (i): the iPhone has
// no help words for it (SettingsHelp), and the web only shows the iPhone's.
import { useState } from "preact/hooks"
import { UPLOAD_QUALITY_CHOICES, UPLOAD_QUALITY_FOOTER, setUploadQuality, uploadQuality, uploadQualityNote } from "../net/upload-quality.js"

export function UploadQualityPicker() {
  const [value, setValue] = useState(() => uploadQuality())
  const pick = v => { setUploadQuality(v); setValue(uploadQuality()) }
  return (
    <>
      <div class="settings-row static send-delay">
        <span class="settings-title"><span id="upload-quality-label">Upload Quality</span></span>
        <div class="seg-pill" role="radiogroup" aria-labelledby="upload-quality-label">
          {UPLOAD_QUALITY_CHOICES.map(c => (
            <button key={c.value} type="button" role="radio" aria-checked={value === c.value} class={value === c.value ? "on" : ""} onClick={() => pick(c.value)}>{c.label}</button>
          ))}
        </div>
      </div>
      <p class="settings-note muted small" aria-live="polite">{uploadQualityNote(value)} {UPLOAD_QUALITY_FOOTER}</p>
    </>
  )
}
