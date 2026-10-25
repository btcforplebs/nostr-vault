// Sign-in with no Nostr extension in this browser: the one to install for it (signer/nip07.js extensionHelp) and a
// way to look again once it's in. Shown by SignInOptions when "Sign in with extension" finds nothing.
import { useState } from "preact/hooks"
import { findExtension, extensionHelp } from "../signer/nip07.js"

/** No extension in this browser: the one to install for it, and a way to look again once it's in. An extension can
 *  appear late, and one installed while the page is open often reaches it only after a reload. */
export function GetExtension({ disabled, onFound }) {
  const help = extensionHelp(navigator.userAgent, { brave: !!navigator.brave, touch: navigator.maxTouchPoints })
  const [looking, setLooking] = useState(false)
  const [missed, setMissed] = useState(false)
  const retry = async () => {
    setLooking(true); setMissed(false)
    const ext = await findExtension(3000)
    setLooking(false)
    if (ext) onFound(); else setMissed(true)
  }
  if (help.note) return <div class="get-extension"><h2>No Nostr extension in {help.browser}</h2><p>{help.note}</p></div>
  return (
    <div class="get-extension">
      <h2>Get {help.name} for {help.browser}</h2>
      <p>{help.what}</p>
      <a class="button primary" href={help.url} target="_blank" rel="noopener noreferrer">Get {help.name} on the {help.store}</a>
      {help.after && <p class="small">{help.after}</p>}
      <button disabled={disabled || looking} onClick={retry} aria-busy={looking || undefined}>{looking ? "Looking for the extension…" : "I installed it, try again"}</button>
      {missed && <p class="small">Still no extension here. If you just installed it, <a href="" onClick={e => { e.preventDefault(); location.reload() }}>reload this page</a> and sign in again.</p>}
    </div>
  )
}
