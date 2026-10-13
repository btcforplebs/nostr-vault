// Sign-in for M1: a NIP-07 extension or a NIP-46 bunker. The user's secret key never comes into this page.
import { useEffect, useState } from "preact/hooks"
import { findExtension, extensionSignIn } from "../signer/nip07.js"
import { bunkerSignIn } from "../signer/nip46.js"
import { pool } from "../net/pool.js"
import { AuthPrompt } from "../components/AuthPrompt.jsx"

export function SignInScreen({ onSignedIn }) {
  const [hasExt, setHasExt] = useState(false)
  const [bunker, setBunker] = useState("")
  const [busy, setBusy] = useState("")
  const [err, setErr] = useState("")
  useEffect(() => { findExtension().then(e => setHasExt(!!e)) }, [])

  const run = (label, fn) => async () => {
    setBusy(label); setErr("")
    try { onSignedIn(await fn()) } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }

  return (
    <main class="signin">
      <img src="./icon.svg" alt="" class="signin-logo" />
      <h1>Nostr Vault</h1>
      <p class="muted">Your relay runs in this browser. Sign in with your own signer: your secret key stays with it.</p>
      {hasExt && <button class="primary" disabled={!!busy} onClick={run("ext", extensionSignIn)}>{busy === "ext" ? "Waiting for the extension…" : "Sign in with extension"}</button>}
      <label class="field">
        <span>Bunker link (NIP-46)</span>
        <input value={bunker} onInput={e => setBunker(e.currentTarget.value)} placeholder="bunker://… or name@domain" autocapitalize="off" autocorrect="off" spellcheck={false} />
      </label>
      <button class={hasExt ? "" : "primary"} disabled={!!busy || !bunker.trim()} onClick={run("bunker", () => bunkerSignIn(bunker, pool))}>
        {busy === "bunker" ? "Approve the connection in your signer…" : "Connect bunker"}
      </button>
      <AuthPrompt />
      {err && <p class="error">{err}</p>}
    </main>
  )
}
