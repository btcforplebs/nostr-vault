// Create an account's "Who showed you this app?" step (iPhone/Android ReferrerStep, only for someone new to Nostr,
// Logen 2026-11-05): their name, npub or NIP-05; pick them and they're added to the people this account follows (it
// follows them once the account is made, with the rest of the follows step). Skippable. Nothing is published here.
import { useEffect, useRef, useState } from "preact/hooks"
import { namesAKey, resolvePubkey } from "../signer/readonly.js"
import { searchPeople } from "../net/search.js"
import { putProfile, fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { PersonRow } from "./SearchScreen.jsx"

export const REFERRER_TITLE = "Who showed you this app?"
// No vault exists yet while an account is being made: their profile is looked up on the relays only, kept in memory.
const NO_VAULT = { feed: { query: async () => [] } }

/** `onFollow(pubkey)`: follow them; `onSkip()`. */
export function ReferrerStep({ onFollow, onSkip }) {
  const [q, setQ] = useState("")
  const [people, setPeople] = useState(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const seq = useRef(0)
  const input = useRef(null)
  useEffect(() => input.current?.focus(), [])

  const submit = async e => {
    e.preventDefault()
    const text = q.trim()
    if (!text) return
    const n = ++seq.current
    setBusy(true); setErr(""); setPeople(null)
    try {
      let found
      if (namesAKey(text)) {
        const pk = await resolvePubkey(text)
        await fetchProfiles(NO_VAULT, [pk], uniq([...PROFILE_RELAYS, ...DEFAULT_RELAYS]), { save: false }).catch(() => {})
        found = [pk]
      } else {
        const evs = await searchPeople(text)
        evs.forEach(putProfile)
        found = evs.map(ev => ev.pubkey)
      }
      if (n === seq.current) setPeople(found)
    } catch (e) { if (n === seq.current) setErr(String(e?.message ?? e)) } finally { if (n === seq.current) setBusy(false) }
  }

  return (
    <>
      <h1 class="onboard-title">{REFERRER_TITLE}</h1>
      <p class="onboard-sub">Type their name, npub or NIP-05 and pick them: your new account will follow them, so your feed starts with someone you know.</p>
      <form class="welcome-browse" role="search" onSubmit={submit}>
        <label class="welcome-search">
          <span class="sr-only">Their name, npub or NIP-05</span>
          <input type="search" value={q} ref={input} onInput={e => { setQ(e.currentTarget.value); setPeople(null); setErr("") }}
            placeholder="Name, npub or NIP-05" autocapitalize="off" autocorrect="off" spellcheck={false} enterkeyhint="search" />
          <button type="submit" class="small" disabled={busy || !q.trim()} aria-busy={busy || undefined}>{busy ? "Looking…" : "Find"}</button>
        </label>
        <div class="welcome-results" aria-live="polite">
          {people?.length === 0 && <p class="muted small">Nobody found by that name. Try their npub or NIP-05.</p>}
          {people?.length > 0 && people.map(pk => <PersonRow key={pk} pubkey={pk} onClick={() => onFollow(pk)} />)}
          {err && <p class="error small">{err}</p>}
        </div>
      </form>
      <button type="button" class="onboard-main" onClick={onSkip}>Skip</button>
    </>
  )
}
