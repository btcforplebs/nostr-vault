// The front door, what nostrvault.app opens on for someone not signed in: one line on what Nostr Vault is, Sign in,
// and a search to look at anyone without an account (their profile opens in the guest view, src/guest/GuestApp.jsx).
// "What is Nostr Vault?" shrinks the app into a phone on the marketing page (src/shell.js).
import { useRef, useState } from "preact/hooks"
import { namesAKey, resolvePubkey } from "../signer/readonly.js"
import { searchPeople } from "../net/search.js"
import { putProfile } from "../net/profiles.js"
import { PersonRow } from "./SearchScreen.jsx"
import { learn } from "../shell.js"
import "../styles/welcome.css"

const SEARCH = "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4"

export function WelcomeScreen({ onSignIn }) {
  return (
    <main class="welcome">
      <div class="welcome-main">
        <img src="./icon.svg" alt="" class="welcome-logo" width="64" height="64" />
        <h1>Nostr Vault <span class="beta">Beta</span></h1>
        <p class="welcome-line">A Nostr app with your own relay inside, so your notes and media live on devices you hold.</p>
        <button class="primary welcome-signin" onClick={onSignIn}>Sign in</button>
        <Browse />
      </div>
      <button type="button" class="welcome-learn" onClick={() => learn()}>
        What is Nostr Vault? <span class="welcome-arrow" aria-hidden="true">↓</span>
      </button>
    </main>
  )
}

/** An npub, NIP-05 or hex opens that profile; a name is searched, and tapping a person opens theirs. */
function Browse() {
  const [q, setQ] = useState("")
  const [people, setPeople] = useState(null) // null: no search yet; []: searched, nobody
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const seq = useRef(0) // a slow answer to an older search must not replace a newer one
  const open = pk => { location.hash = `#/profile/${pk}` }

  const submit = async e => {
    e.preventDefault()
    const text = q.trim()
    if (!text) return
    const n = ++seq.current
    setBusy(true); setErr(""); setPeople(null)
    try {
      if (namesAKey(text)) return open(await resolvePubkey(text))
      const found = await searchPeople(text)
      if (n !== seq.current) return
      found.forEach(putProfile)
      setPeople(found.map(ev => ev.pubkey))
    } catch (e) { if (n === seq.current) setErr(String(e?.message ?? e)) } finally { if (n === seq.current) setBusy(false) }
  }

  return (
    <form class="welcome-browse" role="search" onSubmit={submit}>
      <div class="welcome-or" aria-hidden="true"><span>or look around, no account needed</span></div>
      <label class="welcome-search">
        <span class="sr-only">Find anyone on Nostr by name, npub or NIP-05</span>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d={SEARCH} /></svg>
        <input type="search" value={q} onInput={e => { setQ(e.currentTarget.value); setPeople(null); setErr("") }} placeholder="Name, npub or NIP-05"
          autocapitalize="off" autocorrect="off" spellcheck={false} enterkeyhint="search" />
        <button type="submit" class="small" disabled={busy || !q.trim()} aria-busy={busy || undefined}>{busy ? "Looking…" : "Go"}</button>
      </label>
      <div class="welcome-results" aria-live="polite">
        {people?.length === 0 && <p class="muted small">Nobody found by that name. Try their npub or NIP-05.</p>}
        {people?.length > 0 && people.map(pk => <PersonRow key={pk} pubkey={pk} onClick={() => open(pk)} />)}
        {err && <p class="error small">{err}</p>}
      </div>
    </form>
  )
}
