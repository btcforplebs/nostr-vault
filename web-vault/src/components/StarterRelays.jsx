// Create an account's relay step (the iPhone's StarterRelayListStep): the servers a new account's posts go to, one
// Continue, and a small Change link to edit the list first. What it shows is all that is published (net/new-account.js):
// the relay list (kind 10002) and the DM inbox list (kind 10050), and the first events go to these servers only.
import { useState } from "preact/hooks"
import { starterList } from "../net/new-account.js"

const label = url => url.replace(/^wss:\/\//, "")

/** `relays`: the list now; `setRelays`: kept by Create an account for the last step. A new account needs one server. */
export function StarterRelays({ relays, setRelays, onContinue }) {
  const [changing, setChanging] = useState(false)
  const [draft, setDraft] = useState("")
  const [err, setErr] = useState("")
  const add = e => {
    e.preventDefault()
    let url = draft.trim()
    if (url && !/^\w+:\/\//.test(url)) url = `wss://${url}`
    const [ok] = starterList([url])
    if (!ok) return setErr("Use a wss:// address other people can reach.")
    setRelays(starterList([...relays, ok])); setDraft(""); setErr("")
  }
  return (
    <>
      <h1 class="onboard-title">Your posts will be shared through these servers</h1>
      <ul class="onboard-summary starter-relays" aria-label="Servers">
        {!relays.length && <li class="muted">No servers. Add one below.</li>}
        {relays.map(url => (
          <li key={url} class="starter-relay">
            <span class="starter-relay-url">{label(url)}</span>
            {changing && <button type="button" class="small" onClick={() => setRelays(relays.filter(r => r !== url))} aria-label={`Remove ${label(url)}`}>Remove</button>}
          </li>
        ))}
      </ul>
      {changing && (
        <form class="field" onSubmit={add}>
          <span>Add a server</span>
          <input value={draft} onInput={e => { setDraft(e.currentTarget.value); setErr("") }} placeholder="wss://relay.example.com" autocapitalize="off" autocorrect="off" spellcheck={false} inputMode="url" />
          {err && <span class="error small" role="alert">{err}</span>}
          <button type="submit" class="small" disabled={!draft.trim()}>Add</button>
        </form>
      )}
      <button type="button" class="primary onboard-main" disabled={!relays.length} onClick={() => onContinue(relays)}>Continue</button>
      {!changing && <button type="button" class="onboard-skip" onClick={() => setChanging(true)}>Change</button>}
    </>
  )
}
