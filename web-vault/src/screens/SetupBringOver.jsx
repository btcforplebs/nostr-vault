// Setup's second question, before "Getting your vault ready" (Logen 2026-11-05, as Apple #1761 and Android #1759):
// New to Nostr Vault? Yes: your notes from your relays (today's setup, unchanged). No: copy from your other vault, which
// links the two by two scans, this browser playing the one that scans (lane C pair-flow.js, unchanged; with no camera
// it shows its code instead); on the web the notes still come from the relays after it (Logen's answer 4). Anything
// that doesn't link within the plan's limits goes back to today's setup quietly, with one plain line; "Lost your other
// device?" does it at once. The backup zip left setup (Settings › Backup & Restore, the Dashboard's Keep it full).
// No mesh, FIPS, address or role words here.
import { useEffect, useMemo, useState } from "preact/hooks"
import { ScanFlow, ShowFlow } from "../net/pair-flow.js"
import { browserDeviceName } from "../net/pair-devices.js"
import { displayName, roleConfirmText } from "../net/mesh-pairing.js"
import { COPY, COPY_DETAIL, FALLBACK, LOST_DEVICE, QUESTION, RELAYS, RELAYS_DETAIL, linkedLine, setupNotice, setupOutcome, waitingSince } from "../net/setup-bring-over.js"
import { loadAccounts } from "../session.js"
import { QrCode } from "./WalletReceive.jsx"
import { QrReader } from "../components/QrReader.jsx"
import "../styles/pair.css"
import "../styles/setup-bring-over.css"

/** `onDone({ note })`: go on to today's setup, with the line to show there (none after Import from relays). */
export function SetupBringOver({ pubkey, liveOwners, onDone }) {
  const [mode, setMode] = useState(null) // null: the choice; "scan" | "show"
  if (!mode) {
    return (
      <main class="setup-bring">
        <span class="splash-mark"><img src="./icon.svg" alt="" /></span>
        <h1>{QUESTION}</h1>
        <button type="button" class="setup-choice primary" onClick={() => onDone({ note: null })}>
          <span class="setup-choice-title">{RELAYS}</span><span class="setup-choice-detail">{RELAYS_DETAIL}</span>
        </button>
        <button type="button" class="setup-choice" onClick={() => setMode("scan")}>
          <span class="setup-choice-title">{COPY}</span><span class="setup-choice-detail">{COPY_DETAIL}</span>
        </button>
      </main>
    )
  }
  return <BringOver key={mode} mode={mode} pubkey={pubkey} liveOwners={liveOwners} onMode={setMode} onDone={onDone} />
}

function BringOver({ mode, pubkey, liveOwners, onMode, onDone }) {
  const [view, setView] = useState({ step: "starting" })
  const [since, setSince] = useState(null)
  const flow = useMemo(() => new (mode === "show" ? ShowFlow : ScanFlow)({
    account: pubkey, accounts: loadAccounts().map(a => a.pubkey), name: browserDeviceName(), liveOwners, onChange: setView,
  }), [mode, pubkey])
  useEffect(() => {
    flow.start().catch(() => setView({ step: "failed" }))
    const t = setInterval(() => flow.tick(), 1000)
    return () => { clearInterval(t); flow.stop() }
  }, [flow])
  useEffect(() => {
    const check = () => {
      const now = Math.floor(Date.now() / 1000)
      const s = waitingSince(view, since, now)
      if (s !== since) setSince(s)
      const out = setupOutcome(view, s, now)
      if (out === "linked") onDone({ note: linkedLine(view.device?.name) })
      else if (out === "fallback") { flow.stop(); onDone({ note: FALLBACK }) }
    }
    check()
    const t = setInterval(check, 1000)
    return () => clearInterval(t)
  }, [view, since])

  const other = displayName(view.name)
  const startFresh = <button type="button" class="setup-link" onClick={() => { flow.stop(); onDone({ note: null }) }}>{LOST_DEVICE}</button>
  return (
    <main class="setup-bring" aria-live="polite">
      <span class="splash-mark"><img src="./icon.svg" alt="" /></span>
      {view.step === "starting" && <p class="muted">Getting ready…</p>}

      {view.step === "scanning" && <>
        <h1>Scan your other device</h1>
        <p class="muted">In Nostr Vault on your other device, open Your devices and show its code. Then point this camera at it.</p>
        {!view.cameraOff
          ? <QrReader onCode={t => flow.scanned(t)} onUnavailable={() => flow.noCamera()} label="Camera, looking for your other device's code" />
          : <button type="button" class="primary" onClick={() => onMode("show")}>This browser has no camera: show a code instead</button>}
      </>}

      {view.step === "showing" && <>
        <h1>Scan this with your other device</h1>
        <p class="muted">In Nostr Vault on your other device, open Your devices, choose to scan a code, and point it here.</p>
        <div class="pair-code"><QrCode text={view.qr} label="This browser's code" size={240} /></div>
      </>}

      {view.step === "scanBack" && <>
        <h1>{other} found this browser</h1>
        {!view.cameraOff
          ? <><p class="muted">Now scan the code on its screen.</p><QrReader onCode={t => flow.scanned(t)} onUnavailable={() => flow.noCamera()} /></>
          : <Words words={view.words} lead={`Check ${other} shows these four words:`} onMatch={() => flow.accept()} />}
      </>}

      {view.step === "showBack" && <>
        <h1>Now let {other} scan this</h1>
        <div class="pair-code"><QrCode text={view.qr} label="This browser's reply code" size={240} /></div>
        {view.wordsTapped ? <p class="muted">Waiting for {other}…</p>
          : <Words words={view.words} strong={view.waitWords}
              lead={view.waitWords ? `${other} shows four words. Check they match:` : `If ${other} can't scan, it shows four words. Check they match:`}
              onMatch={() => flow.confirmWords()} />}
      </>}

      {view.step === "confirm" && <>
        <h1>Add {displayName(view.device.name)}?</h1>
        <p>{roleConfirmText(view.device.role, view.device.name, true)}</p>
        <button type="button" class="primary" onClick={() => flow.confirmRole()}>Add</button>
      </>}

      {view.notice && <p class="pair-notice" role="alert">{setupNotice(view.notice)}</p>}
      {view.step !== "confirm" && startFresh}
    </main>
  )
}

function Words({ words, lead, onMatch, strong }) {
  return (
    <div class={`pair-words${strong ? " strong" : ""}`}>
      <p>{lead}</p>
      <ol class="pair-word-list">{(words ?? []).map(w => <li key={w}>{w}</li>)}</ol>
      <button type="button" class="primary" onClick={onMatch}>They match</button>
    </div>
  )
}
