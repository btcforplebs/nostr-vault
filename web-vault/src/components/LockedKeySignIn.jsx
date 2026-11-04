// Sign-in with a password-locked key (NIP-49 ncryptsec), the copy Nostr Vault and other apps export (signer/local.js
// lockedKeySession). The secret key in the clear is never typed here: only the locked key and its password.
import { useState } from "preact/hooks"
import { lockedKeySession, localSigner } from "../signer/local.js"

export function LockedKeySignIn({ disabled, onSignedIn }) {
  const [open, setOpen] = useState(false)
  const [locked, setLocked] = useState("")
  const [password, setPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  if (!open) return <button type="button" disabled={disabled} onClick={() => setOpen(true)}>I have a password-locked key (ncryptsec)</button>
  const submit = async e => {
    e.preventDefault()
    setBusy(true); setErr("")
    try {
      const session = await lockedKeySession(locked, password)
      setPassword("")
      await onSignedIn({ signer: localSigner(session), session })
    } catch (e2) { setErr(String(e2?.message ?? e2)) } finally { setBusy(false) }
  }
  return (
    <form class="locked-key-signin" onSubmit={submit}>
      <label class="field">
        <span>Password-locked key (NIP-49)</span>
        <input value={locked} onInput={e => setLocked(e.currentTarget.value)} placeholder="ncryptsec1…" autocapitalize="off" autocorrect="off" spellcheck={false} autocomplete="off" />
      </label>
      <label class="field">
        <span>Its password</span>
        <input type="password" value={password} onInput={e => setPassword(e.currentTarget.value)} autocomplete="current-password" />
      </label>
      <button type="submit" disabled={disabled || busy || !locked.trim() || !password} aria-busy={busy || undefined}>
        {busy ? "Opening your key…" : "Sign in"}
      </button>
      <p class="muted small">The password opens the key here, in this browser. The key is kept locked; nothing is sent.</p>
      {err && <p class="error">{err}</p>}
    </form>
  )
}
