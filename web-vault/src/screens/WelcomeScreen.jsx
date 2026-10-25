// The front door, what nostrvault.app opens on for someone not signed in, laid out as the iPhone's first screen
// (WelcomeStepView): the vault mark, "kept on your own device", three chips, and the ways in pinned at the bottom.
// Create an account (screens/CreateAccount.jsx, the iPhone's New to Nostr), I already use Nostr (sign-in), and, as the
// Mac's "Just look around", a small link that opens a search to look at anyone without an account (their profile
// opens in the guest view, src/guest/GuestApp.jsx). "What is Nostr Vault?" (the iPhone's "What's inside?") shrinks the
// app into a phone on the marketing page (src/shell.js).
import { useEffect, useRef, useState } from "preact/hooks"
import { namesAKey, resolvePubkey } from "../signer/readonly.js"
import { searchPeople } from "../net/search.js"
import { putProfile } from "../net/profiles.js"
import { PersonRow } from "./SearchScreen.jsx"
import { learn } from "../shell.js"
import "../styles/welcome.css"

const SEARCH = "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4"
// The iPhone's chips, SF Symbols drawn on a 24 grid: externaldrive.connected.to.line.below, lock.shield, bolt.fill.
const CHIPS = [
  ["Own relay", <><rect x="3" y="3.5" width="18" height="9" rx="2.5" /><path d="M7 8h.01M12 12.5V17M3 20.5h6M15 20.5h6" /><circle cx="12" cy="19.5" r="1.6" /></>],
  ["Private DMs", <><path d="M12 2.8 4.5 5.6v6c0 4.6 3.1 8.2 7.5 9.6 4.4-1.4 7.5-5 7.5-9.6v-6z" /><rect x="9" y="11" width="6" height="4.6" rx="1" /><path d="M10.2 11V9.6a1.8 1.8 0 0 1 3.6 0V11" /></>],
  ["Zaps", <path d="M13.4 2.5 5 13.6h6l-1.4 7.9L18 10.4h-6z" fill="currentColor" />],
]

export function WelcomeScreen({ onSignIn, onCreate }) {
  const [looking, setLooking] = useState(false)
  return (
    <main class="welcome">
      <div class="welcome-hero">
        <span class="welcome-mark"><img src="./icon.svg" alt="" width="112" height="112" /></span>
        <h1>Nostr Vault</h1>
        <p class="welcome-line">Your posts, messages and media,<br />kept on your own device.</p>
        <ul class="welcome-chips" aria-label="Includes your own relay, private DMs and zaps">
          {CHIPS.map(([label, d]) => (
            <li key={label} aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{d}</svg>{label}</li>
          ))}
        </ul>
        <button type="button" class="welcome-learn" onClick={() => learn()}>What is Nostr Vault?</button>
      </div>
      <div class="welcome-actions">
        <button class="welcome-door primary" onClick={onCreate}>Create an account</button>
        <button class="welcome-door" onClick={onSignIn}>I already use Nostr</button>
        {looking ? <Browse /> : <button type="button" class="welcome-look" onClick={() => setLooking(true)}>Just look around</button>}
      </div>
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
  const input = useRef(null)
  useEffect(() => input.current?.focus(), []) // opened by "Just look around": ready to type

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
      <label class="welcome-search">
        <span class="sr-only">Find anyone on Nostr by name, npub or NIP-05</span>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d={SEARCH} /></svg>
        <input type="search" value={q} onInput={e => { setQ(e.currentTarget.value); setPeople(null); setErr("") }} placeholder="Name, npub or NIP-05"
          ref={input} autocapitalize="off" autocorrect="off" spellcheck={false} enterkeyhint="search" />
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
