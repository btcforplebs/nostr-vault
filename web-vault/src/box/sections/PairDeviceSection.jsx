// Box › My Devices › Add a device: two-scan pairing with the box as the device that shows the code
// (docs/MESH_PAIRING_CONTRACT.md §8). The box has no camera, so it finishes with the four check words: the person
// checks them against the phone and taps They match, which also confirms the role shown. `api`: a boxApi
// (api-devices.js pairStart, pairStatus, pairConfirm, pairCancel). `onPaired`: called once a device is linked, so the
// device list reloads. The screen's words are pair-device.js; the code is drawn by components/QrCode.jsx.
import { useEffect, useState } from "preact/hooks"
import { QrCode } from "../../components/QrCode.jsx"
import { pairView } from "../pair-device.js"

const POLL_MS = 2000

export function PairDeviceSection({ api, onPaired, poll = POLL_MS }) {
  const [status, setStatus] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [tick, setTick] = useState(0)

  const ask = fn => {
    setBusy(true); setError(null)
    return fn().then(setStatus, e => setError(String(e?.message ?? e))).finally(() => setBusy(false))
  }
  // While a code is shown or a device waits, ask the box every couple of seconds; the countdown ticks each second.
  useEffect(() => {
    if (!status || !["waiting", "hello"].includes(status.state)) return
    const t = setInterval(() => api.pairStatus().then(setStatus, () => {}), poll)
    const c = setInterval(() => setTick(n => n + 1), 1000)
    return () => { clearInterval(t); clearInterval(c) }
  }, [status?.state, api, poll])
  useEffect(() => { if (status?.state === "linked" && status.acked > 0) onPaired?.() }, [status?.state])

  const v = pairView(status)
  void tick
  return (
    <div class="settings-rows box-pair" data-step={v.step}>
      <div class="settings-row box-row"><span class="settings-title">{v.title}</span>
        {v.canStart && <button type="button" class="small" disabled={busy} onClick={() => ask(api.pairStart)}>{v.step === "idle" ? "Add a device" : "Show a new code"}</button>}
        {v.canCancel && <button type="button" class="small" disabled={busy} onClick={() => ask(api.pairCancel)}>Cancel</button>}
      </div>
      <p class="muted small box-pad">{v.text}</p>
      {v.step === "waiting" && v.code && <div class="box-pad box-pair-code">
        <QrCode text={v.code} label="Pairing code for your phone" size={220} />
        <p class="muted small">Expires in {v.secondsLeft} s. <span class="box-pair-text">{v.code}</span></p>
      </div>}
      {v.step === "hello" && <div class="box-pad">
        {v.canConfirm
          ? <>
            <p class="box-pair-words" aria-label="Check words">{v.words.map(w => <span key={w} class="box-pair-word">{w}</span>)}</p>
            <p class="small">{v.confirmText}</p>
            <button type="button" disabled={busy} onClick={() => ask(() => api.pairConfirm(v.role))}>They match: add this {v.roleWord}</button>
          </>
          : <p class="error small" role="alert">The box sent no check words for this device. Cancel and show a new code.</p>}
        <p class="muted small">{v.secondsLeft} s left.</p>
      </div>}
      {v.refusal && <p class="error small box-pad" role="alert">{v.refusal}</p>}
      {(error || v.error) && <p class="error small box-pad" role="alert">{error || v.error}</p>}
    </div>
  )
}
