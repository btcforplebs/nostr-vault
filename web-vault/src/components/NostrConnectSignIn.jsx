// Sign in by scanning: a nostrconnect:// QR code for Amber (or Clave, nsec.app, any NIP-46 signer app). The page waits
// for the app's answer on the relays in the code (signer/nip46.js nostrConnectSignIn). On a phone, the same link opens
// the signer app directly. Nothing starts until the user asks for the code, so the page opens no relay for it before.
import { useEffect, useRef, useState } from "preact/hooks"
import { nostrConnectRequest, nostrConnectSignIn } from "../signer/nip46.js"
import { QrCode } from "./QrCode.jsx"

/** `onSignedIn({ signer, session })`; `onBusy(bool)` while the app's approval is coming in; `primary` styles the button. */
export function NostrConnectSignIn({ pool, onSignedIn, disabled, primary, onBusy }) {
  const [req, setReq] = useState(null)
  const [state, setState] = useState("") // "", "waiting", "finishing"
  const [err, setErr] = useState("")
  const [copied, setCopied] = useState(false)
  const wait = useRef(null)
  const stop = () => { wait.current?.cancel(); wait.current = null }
  useEffect(() => stop, [])

  const start = () => {
    stop(); setErr(""); setCopied(false)
    const r = nostrConnectRequest()
    const w = nostrConnectSignIn(r, pool)
    wait.current = w
    setReq(r); setState("waiting")
    w.done.then(async result => {
      if (wait.current !== w) return
      setState("finishing"); onBusy?.(true)
      try { await onSignedIn(result) } catch (e) { setErr(String(e?.message ?? e)); setState("") } finally { onBusy?.(false) }
    }, e => {
      if (e?.cancelled || wait.current !== w) return
      wait.current = null; setErr(String(e?.message ?? e)); setState(""); setReq(null)
    })
  }
  const cancel = () => { stop(); setReq(null); setState(""); setErr("") }
  const copy = async () => { try { await navigator.clipboard.writeText(req.uri); setCopied(true); setTimeout(() => setCopied(false), 2000) } catch {} }

  if (!req) {
    return (
      <>
        <button class={primary ? "primary" : ""} disabled={disabled} onClick={start}>Sign in with Amber or a signer app</button>
        {err && <p class="error">{err}</p>}
      </>
    )
  }
  return (
    <div class="card nostrconnect-signin">
      <p class="nostrconnect-title">Scan with your signer app</p>
      <div class="pair-code"><QrCode text={req.uri} label="Nostr Connect code for your signer app" size={280} /></div>
      <p class="muted small" aria-live="polite">{state === "finishing" ? "Approved. Signing in…" : "Scan it with Amber (or Clave, nsec.app) on your phone and approve Nostr Vault. This page signs in by itself."}</p>
      <div class="row">
        {/* On a phone, where the signer app is, the link opens it (Amber registers nostrconnect://); a desktop scans. */}
        {onPhone() && <a class="button primary" href={req.uri}>Open in signer app</a>}
        <button type="button" onClick={copy}>{copied ? "Copied!" : "Copy link"}</button>
        <button type="button" onClick={cancel} disabled={state === "finishing"}>Cancel</button>
      </div>
      {err && <p class="error">{err}</p>}
    </div>
  )
}

const onPhone = () => !!globalThis.matchMedia?.("(pointer: coarse)").matches
