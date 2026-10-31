// Settings › Posting › Send Delay (iPhone FeedSettingsView's segmented picker): Off, 5s or 10s before a post, reply or
// quote goes out, with its countdown and Undo (net/send-delay.js). Read fresh at each send, so a change applies to
// the next one.
import { useState } from "preact/hooks"
import { SEND_DELAY_CHOICES, sendDelaySeconds, setSendDelaySeconds, sendDelayNote } from "../net/send-delay.js"

export const choiceLabel = s => (s === 0 ? "Off" : `${s}s`)

export function SendDelayPicker() {
  const [seconds, setSeconds] = useState(() => sendDelaySeconds())
  const pick = s => { setSendDelaySeconds(s); setSeconds(sendDelaySeconds()) }
  return (
    <>
      <div class="settings-row static send-delay">
        <span class="settings-title" id="send-delay-label">Send Delay</span>
        <div class="seg-pill" role="radiogroup" aria-labelledby="send-delay-label">
          {SEND_DELAY_CHOICES.map(s => (
            <button key={s} type="button" role="radio" aria-checked={seconds === s} class={seconds === s ? "on" : ""} onClick={() => pick(s)}>{choiceLabel(s)}</button>
          ))}
        </div>
      </div>
      <p class="settings-note muted small" aria-live="polite">{sendDelayNote(seconds)}</p>
    </>
  )
}
