// Accounts & Keys › an account › Reveal Key (iPhone AccountDetailView): for an account whose key was made in this
// browser (method "local"), its nsec after a warning and its password (signer/local.js revealNsec, which opens the
// ncryptsec and checks the key is this account's). Extension and bunker accounts never draw it: no key is kept here.
// The nsec lives in this component's state only and goes on Hide, Cancel or closing the account.
import { useState } from "preact/hooks"
import { revealNsec } from "../signer/local.js"
import { KeyCard, painted } from "./KeyCard.jsx"
import { SettingInfo } from "./SettingInfo.jsx"
import { canReveal } from "./reveal-key.js"

export const REVEAL_WARNING = "Anyone who has your secret key can post as you and read your messages, for good. Only reveal it where nobody can see your screen, and never paste it into a website."

export function RevealKey({ account }) {
  const [step, setStep] = useState("") // "" | "confirm" | "shown"
  const [pw, setPw] = useState("")
  const [nsec, setNsec] = useState("")
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState(false)
  if (!canReveal(account)) return null
  const close = () => { setStep(""); setPw(""); setNsec(""); setErr("") }
  const show = async e => {
    e.preventDefault(); setErr(""); setBusy(true)
    await painted() // scrypt holds the page for a moment: show "Opening…" first
    try { setNsec(revealNsec(account, pw)); setPw(""); setStep("shown") } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  if (step === "shown") return (
    <div class="reveal-key">
      <KeyCard title="Secret key" secret caption="Anyone who has it can post as you, so never share it." value={nsec} />
      <button type="button" onClick={close}>Hide</button>
    </div>
  )
  if (step === "confirm") return (
    <form class="card reveal-key" onSubmit={show}>
      <p class="onboard-warn box">{REVEAL_WARNING}</p>
      <input type="text" name="username" autocomplete="username" value="Nostr Vault key" hidden readOnly />
      <label class="field"><span>Password</span>
        <input type="password" value={pw} onInput={e => setPw(e.currentTarget.value)} autocomplete="current-password" required /></label>
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="row">
        <button type="submit" class="danger" disabled={!pw || busy} aria-busy={busy || undefined}>{busy ? "Opening…" : "Reveal Key"}</button>
        <button type="button" disabled={busy} onClick={close}>Cancel</button>
      </div>
    </form>
  )
  return <div class="row"><button type="button" onClick={() => setStep("confirm")}>Reveal Key</button><SettingInfo topic="account.revealKey" /></div>
}
