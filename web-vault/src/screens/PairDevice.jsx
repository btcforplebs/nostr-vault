// Link one of your devices to this browser vault by two scans (plan §3, contract docs/MESH_PAIRING_CONTRACT.md), shown
// inside the Vault Dashboard. "show": this browser shows its code and then scans the other device's reply (A).
// "scan": this browser scans the other device's code and shows its reply (B). The steps are pair-flow.js; this draws
// them. With no usable camera, A offers Accept with the 4 check words, and B offers "Show this browser's code instead".
import { useEffect, useMemo, useState } from "preact/hooks"
import { ShowFlow, ScanFlow } from "../net/pair-flow.js"
import { browserDeviceName } from "../net/pair-devices.js"
import { displayName } from "../net/mesh-pairing.js"
import { loadAccounts } from "../session.js"
import { QrCode } from "./WalletReceive.jsx"
import { QrReader } from "../components/QrReader.jsx"
import "../styles/pair.css"

const left = (until, now) => {
  const s = Math.max(0, until - now)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
}

export function PairDevice({ ctx, mode, onMode, onClose }) {
  const [view, setView] = useState({ step: "starting" })
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  const flow = useMemo(() => {
    const Kind = mode === "scan" ? ScanFlow : ShowFlow
    return new Kind({
      account: ctx.session.pubkey,
      accounts: loadAccounts().map(a => a.pubkey),
      name: browserDeviceName(),
      liveOwners: ctx.vault?.owners,
      onChange: v => setView(v),
    })
  }, [mode, ctx.session.pubkey])
  const start = () => flow.start().catch(e => setView({ step: "failed", text: `Couldn't start: ${e?.message ?? e}` }))
  useEffect(() => {
    start()
    const t = setInterval(() => { setNow(Math.floor(Date.now() / 1000)); flow.tick() }, 1000)
    return () => { clearInterval(t); flow.stop() }
  }, [flow])

  const other = displayName(view.name ?? view.device?.name)
  return (
    <div class="pair" aria-live="polite">
      {view.step === "starting" && <p class="muted">Getting ready…</p>}

      {view.step === "showing" && <>
        <h3>Show this code to your other device</h3>
        <p class="muted">On your other device, open Your devices, choose to scan a code, and point it at this.</p>
        <div class="pair-code"><QrCode text={view.qr} label="This browser's pairing code" size={240} /></div>
        <p class="muted small">Works once. Expires in {left(view.expiresAt, now)}.</p>
      </>}

      {view.step === "scanBack" && <>
        <h3>{other} scanned this browser</h3>
        {!view.cameraOff
          ? <><p class="muted">Scan its screen to finish.</p><QrReader onCode={t => flow.scanned(t)} onUnavailable={() => flow.noCamera()} /></>
          : <Words words={view.words} address={view.address} lead={`This browser can't use a camera. Check ${other} shows these four words:`}
              action="They match" onAction={() => flow.accept()} />}
        <p class="muted small">{left(view.expiresAt, now)} left.</p>
      </>}

      {view.step === "scanning" && <>
        <h3>Scan the code on your other device</h3>
        <p class="muted">On it, open Your devices and show its code.</p>
        {!view.cameraOff && <QrReader onCode={t => flow.scanned(t)} onUnavailable={() => flow.noCamera()} />}
        {view.cameraOff && <button type="button" class="primary" onClick={() => onMode("show")}>Show this browser's code instead</button>}
      </>}

      {view.step === "showBack" && <>
        <h3>Now let {other} scan this</h3>
        <div class="pair-code"><QrCode text={view.qr} label="This browser's reply code" size={240} /></div>
        {view.wordsTapped
          ? <p class="muted">Waiting for {other}…</p>
          : <Words words={view.words} address={view.address} strong={view.waitWords}
              lead={view.waitWords ? `${other} accepted with the check words. Check they match:` : `If ${other} can't scan, it shows four words. Check they match:`}
              action="They match" onAction={() => flow.confirmWords()} />}
        <p class="muted small">{left(view.expiresAt, now)} left.</p>
      </>}

      {view.step === "confirm" && <>
        <h3>Add {displayName(view.device.name)}?</h3>
        <p>{view.text}</p>
        <div class="pair-actions">
          <button type="button" class="primary" onClick={() => flow.confirmRole()}>Add</button>
          <button type="button" onClick={onClose}>Cancel</button>
        </div>
      </>}

      {view.step === "linked" && <>
        <h3 class="pair-ok">Linked ✓ {displayName(view.device.name)}</h3>
        <p class="muted">It shows a green dot under Your devices once both are online.</p>
        <button type="button" class="primary" onClick={onClose}>Done</button>
      </>}

      {view.step === "already" && <>
        <h3>{view.text}</h3>
        <button type="button" class="primary" onClick={onClose}>Done</button>
      </>}

      {["refused", "expired", "aborted", "failed"].includes(view.step) && <>
        <p role="alert">{view.text}</p>
        <div class="pair-actions">
          {view.step !== "refused" && <button type="button" class="primary" onClick={start}>Start again</button>}
          <button type="button" onClick={onClose}>Close</button>
        </div>
      </>}

      {view.notice && <p class="pair-notice" role="alert">{view.notice}</p>}
    </div>
  )
}

/** The 4 check words with the other device's short address, and the tap that says they match (contract §5). */
function Words({ words, address, lead, action, onAction, strong }) {
  return (
    <div class={`pair-words${strong ? " strong" : ""}`}>
      <p>{lead}</p>
      <ol class="pair-word-list">{(words ?? []).map(w => <li key={w}>{w}</li>)}</ol>
      <p class="muted small mono">{address}</p>
      <button type="button" class="primary" onClick={onAction}>{action}</button>
    </div>
  )
}
