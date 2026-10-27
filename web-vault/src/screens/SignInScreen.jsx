// Sign-in: a NIP-07 extension or a NIP-46 bunker. The user's secret key never comes into this page.
// The same options add an account on the Accounts screen; accounts this browser already remembers are listed first.
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { findExtension, extensionSignIn } from "../signer/nip07.js"
import { bunkerSignIn } from "../signer/nip46.js"
import { ReadOnlySignIn } from "../components/ReadOnlySignIn.jsx"
import { GetExtension } from "../components/GetExtension.jsx"
import { signerFor } from "../signer/index.js"
import { checkExtensionAccount } from "../signer/accounts.js"
import { loadAccounts } from "../session.js"
import { pool } from "../net/pool.js"
import { AuthPrompt } from "../components/AuthPrompt.jsx"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { StorageNote, askToKeep } from "../components/StorageNote.jsx"
import { learn } from "../shell.js"
import "../styles/accounts.css"

/** `onCreate`: Create an account (screens/CreateAccount.jsx), for someone new to Nostr. */
export function SignInScreen({ onSignedIn, onCreate }) {
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
      {/* The iPhone's UseNostrKeyStep heading. */}
      <h1>Who are you on Nostr?</h1>
      <p class="muted">Sign in with your own signer, a browser extension or a bunker link: your secret key stays with it. Or just look, read-only.</p>
      {cameForPost() && <p class="signin-for-post">Sign in to reply, like or zap the post you opened. Just looking works too.</p>}
      {saved.length > 0 && <div class="saved-accounts">
        {saved.map(a => <SavedAccount key={a.pubkey} account={a} busy={busy === a.pubkey} disabled={!!busy} onClick={resume(a)} />)}
        <p class="muted small">Or sign in as someone else:</p>
      </div>}
      {onCreate && <button class="primary" onClick={onCreate}>New to Nostr? Create an account</button>}
      <SignInOptions onSignedIn={signedIn} />
      <StorageNote />
      <p class="muted small signin-home">New to Nostr Vault? <a href="/#about" onClick={e => { e.preventDefault(); learn() }}>See what it is, and get the apps</a>.</p>
      {err && <p class="error">{err}</p>}
    </main>
  )
}

/** Opened from a shared post's page (nostrvault.app/thread/…), which links here with the post in the address. */
const cameForPost = () => /^#\/(thread\/|feed\?(.*&)?note=)[0-9a-f]{64}/.test(location.hash)

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
export const methodLabel = account => account.method === "nip46" ? "Remote signer (bunker)" : account.method === "readonly" ? "Read-only" : account.method === "local" ? "Key in this browser" : "Browser extension"

/** The extension button and the bunker field. onSignedIn({ signer, session }). Also the Accounts screen's "Add". */
export function SignInOptions({ onSignedIn }) {
  const [hasExt, setHasExt] = useState(null) // null: still looking
  const [showHelp, setShowHelp] = useState(false)
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
      {hasExt === false && !showHelp && <button onClick={() => setShowHelp(true)}>Sign in with extension</button>}
      {hasExt === false && showHelp && <GetExtension disabled={!!busy} onFound={() => { setHasExt(true); run("ext", extensionSignIn)() }} />}
      <label class="field">
        <span>Bunker link (NIP-46)</span>
        <input value={bunker} onInput={e => setBunker(e.currentTarget.value)} placeholder="bunker://… or name@domain" autocapitalize="off" autocorrect="off" spellcheck={false} />
      </label>
      <button class={hasExt === false && !showHelp ? "primary" : ""} disabled={!!busy || !bunker.trim()} onClick={run("bunker", () => bunkerSignIn(bunker, pool))} aria-busy={busy === "bunker" || undefined}>
        {busy === "bunker" ? "Approve the connection in your signer…" : "Connect bunker"}
      </button>
      <ReadOnlySignIn disabled={!!busy} onSignedIn={onSignedIn} />
      <AuthPrompt />
      {err && <p class="error">{err}</p>}
    </>
  )
}
