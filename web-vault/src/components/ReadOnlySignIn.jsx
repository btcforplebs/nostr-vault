// Read-only sign-in: an npub or NIP-05 goes straight in; a name is searched, and tapping a person signs in as them.
// No signer either way (signer/readonly.js).
import { useRef, useState } from "preact/hooks"
import { readonlySignIn, namesAKey } from "../signer/readonly.js"
import { searchPeople } from "../net/search.js"
import { putProfile } from "../net/profiles.js"
import { PersonRow } from "../screens/SearchScreen.jsx"

export function ReadOnlySignIn({ disabled, onSignedIn }) {
  const [who, setWho] = useState("")
  const [people, setPeople] = useState(null) // null: no search yet; []: searched, nobody
  const [busy, setBusy] = useState("")
  const [err, setErr] = useState("")
  const seq = useRef(0) // a slow answer to an older search must not replace a newer one

  const enter = async (input, label) => {
    setBusy(label); setErr("")
    try { await onSignedIn(await readonlySignIn(input)) } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const submit = async e => {
    e.preventDefault()
    const q = who.trim()
    if (!q) return
    if (namesAKey(q)) return enter(q, "key")
    const n = ++seq.current
    setBusy("search"); setErr(""); setPeople(null)
    try {
      const found = await searchPeople(q)
      if (n !== seq.current) return
      found.forEach(putProfile)
      setPeople(found.map(ev => ev.pubkey))
    } catch (e) { if (n === seq.current) setErr(String(e?.message ?? e)) } finally { if (n === seq.current) setBusy("") }
  }

  return (
    <form class="readonly-signin" onSubmit={submit}>
      <label class="field">
        <span>Or just look: your name, npub or NIP-05 (read-only)</span>
        <input value={who} onInput={e => { setWho(e.currentTarget.value); setPeople(null) }} placeholder="Your name, npub1… or you@example.com" autocapitalize="off" autocorrect="off" spellcheck={false} />
      </label>
      <button type="submit" disabled={disabled || !!busy || !who.trim()}>
        {busy === "search" ? "Searching…" : busy ? "Looking you up…" : namesAKey(who) ? "Sign in read-only" : "Find me"}
      </button>
      {people?.length === 0 && <p class="muted small">Nobody found by that name. Try your npub or NIP-05 instead.</p>}
      {people?.length > 0 && <>
        <p class="muted small">Tap yourself to look around read-only:</p>
        {people.map(pk => <PersonRow key={pk} pubkey={pk} onClick={disabled || busy ? undefined : () => enter(pk, pk)} />)}
      </>}
      {err && <p class="error">{err}</p>}
    </form>
  )
}
