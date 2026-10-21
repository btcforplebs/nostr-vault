// Sign-in: a NIP-07 extension or a NIP-46 bunker. The user's secret key never comes into this page.
// The same options add an account on the Accounts screen; accounts this browser already remembers are listed first.
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { findExtension, extensionSignIn } from "../signer/nip07.js"
import { bunkerSignIn } from "../signer/nip46.js"
import { ReadOnlySignIn } from "../components/ReadOnlySignIn.jsx"
import { signerFor } from "../signer/index.js"
import { checkExtensionAccount } from "../signer/accounts.js"
import { loadAccounts } from "../session.js"
import { pool } from "../net/pool.js"
import { AuthPrompt } from "../components/AuthPrompt.jsx"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { StorageNote, askToKeep } from "../components/StorageNote.jsx"
import "../styles/accounts.css"

export function SignInScreen({ onSignedIn }) {
  const [saved] = useState(loadAccounts)
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState("")
  // After sign-in, ask the browser to keep its copy. Not awaited: a browser that asks the user must not hold up
  // sign-in. The Relay screen shows the answer.
  const signedIn = r => { onSignedIn(r); askToKeep() }
  const resume = account => async () => {
    setBusy(account.pubkey); setErr("")
    try {
      if (account.method === "nip07") await checkExtensionAccount(account)
      signedIn({ signer: signerFor(account, pool), session: account })
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }

  return (
    <main class="signin">
      <img src="./icon.svg" alt="" class="signin-logo" />
      <h1>Nostr Vault</h1>
      <p class="muted">Your posts, messages and media, kept in this browser. Sign in with your own signer: your secret key stays with it.</p>
      {saved.length > 0 && <div class="saved-accounts">
        {saved.map(a => <SavedAccount key={a.pubkey} account={a} busy={busy === a.pubkey} disabled={!!busy} onClick={resume(a)} />)}
        <p class="muted small">Or sign in as someone else:</p>
      </div>}
      <SignInOptions onSignedIn={signedIn} />
      <StorageNote />
      {err && <p class="error">{err}</p>}
    </main>
  )
}

function SavedAccount({ account, busy, disabled, onClick }) {
  const p = useProfile(account.pubkey)
  return (
    <button class="person-row" disabled={disabled} onClick={onClick}>
      <Avatar pubkey={account.pubkey} size={40} />
      <span class="person-names">
        <span class="author-name">{busy ? "Signing in…" : `Continue as ${accountName(account, p)}`}</span>
        <span class="person-sub">{methodLabel(account)}</span>
      </span>
    </button>
  )
}

export const accountName = (account, profile) => profile?.name || npubEncode(account.pubkey).slice(0, 16) + "…"
export const methodLabel = account => account.method === "nip46" ? "Remote signer (bunker)" : account.method === "readonly" ? "Read-only" : "Browser extension"

/** The extension button and the bunker field. onSignedIn({ signer, session }). Also the Accounts screen's "Add". */
export function SignInOptions({ onSignedIn }) {
  const [hasExt, setHasExt] = useState(false)
  const [bunker, setBunker] = useState("")
  const [busy, setBusy] = useState("")
  const [err, setErr] = useState("")
  useEffect(() => { findExtension().then(e => setHasExt(!!e)) }, [])

  const run = (label, fn) => async () => {
    setBusy(label); setErr("")
    try { await onSignedIn(await fn()) } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }

  return (
    <>
      {hasExt && <button class="primary" disabled={!!busy} onClick={run("ext", extensionSignIn)} aria-busy={busy === "ext" || undefined}>{busy === "ext" ? "Waiting for the extension…" : "Sign in with extension"}</button>}
      <label class="field">
        <span>Bunker link (NIP-46)</span>
        <input value={bunker} onInput={e => setBunker(e.currentTarget.value)} placeholder="bunker://… or name@domain" autocapitalize="off" autocorrect="off" spellcheck={false} />
      </label>
      <button class={hasExt ? "" : "primary"} disabled={!!busy || !bunker.trim()} onClick={run("bunker", () => bunkerSignIn(bunker, pool))} aria-busy={busy === "bunker" || undefined}>
        {busy === "bunker" ? "Approve the connection in your signer…" : "Connect bunker"}
      </button>
      <ReadOnlySignIn disabled={!!busy} onSignedIn={onSignedIn} />
      <AuthPrompt />
      {err && <p class="error">{err}</p>}
    </>
  )
}
