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
  // On a phone the signer app is on the same screen: opening it is the way in, so that button leads and the code is
  // smaller, for scanning from another device. A desktop leads with the code.
  const phone = onPhone()
  return (
    <div class="card nostrconnect-signin">
      <p class="nostrconnect-title">{phone ? "Sign in with your signer app" : "Scan with your signer app"}</p>
      {phone && <a class="button primary" href={req.uri}>Open in signer app</a>}
      <div class="pair-code"><QrCode text={req.uri} label="Nostr Connect code for your signer app" size={phone ? 180 : 240} ecc="L" /></div>
      <p class="muted small" aria-live="polite">{state === "finishing" ? "Approved. Signing in…" : phone ? "Or scan this code from another device. Approve Nostr Vault in the app and come back: this page signs in by itself." : "Scan it with Amber (or Clave, nsec.app) on your phone and approve Nostr Vault. This page signs in by itself."}</p>
      <div class="row">
        <button type="button" onClick={copy}>{copied ? "Copied!" : "Copy link"}</button>
        <button type="button" onClick={cancel} disabled={state === "finishing"}>Cancel</button>
      </div>
      {err && <p class="error">{err}</p>}
    </div>
  )
}

const onPhone = () => !!globalThis.matchMedia?.("(pointer: coarse)").matches
