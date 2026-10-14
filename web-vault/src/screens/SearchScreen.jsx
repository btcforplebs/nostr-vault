// Search: a box, then People (kind 0) and Notes (kind 1) from the NIP-50 search relays. A pasted npub / nprofile /
// hex pubkey skips the search and opens that profile (onProfile; main.jsx routes it to #/profile/<pubkey>).
import { useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { NoteCard } from "../components/NoteCard.jsx"
import { useProfile } from "../components/useProfile.js"
import { parseQuery, searchNostr } from "../net/search.js"
import { fetchProfiles, putProfile } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { visibleNotes, visiblePeople } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"

export function SearchScreen({ ctx, onProfile }) {
  const [text, setText] = useState("")
  const [result, setResult] = useState(null) // null | { people: [pubkey], notes: [event], direct? }
  const [status, setStatus] = useState("")
  const seq = useRef(0) // a slow answer to an older query must not replace a newer one
  const { blocked } = useBlocks(ctx)

  const submit = async e => {
    e.preventDefault()
    const q = parseQuery(text)
    const n = ++seq.current
    if (q.type === "empty") { setResult(null); setStatus(""); return }
    if (q.type === "profile") {
      setResult({ people: [q.pubkey], notes: [], direct: true }); setStatus("")
      fetchProfiles(ctx.vault, [q.pubkey], uniq([...q.relays, ...ctx.account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
      onProfile?.(q.pubkey)
      return
    }
    if (!navigator.onLine) { setStatus("Offline: search needs the network"); return }
    setStatus("Searching…")
    try {
      const { people, notes } = await searchNostr(q.text)
      if (n !== seq.current) return
      people.forEach(putProfile)
      setResult({ people: people.map(ev => ev.pubkey), notes })
      fetchProfiles(ctx.vault, notes.map(ev => ev.pubkey), ctx.account.relays.read).catch(() => {})
      setStatus("")
    } catch (err) {
      if (n === seq.current) setStatus(`Search failed (${err?.message ?? err})`)
    }
  }

  // A pasted npub still opens that profile, blocked or not: that is the way to find someone to unblock them.
  const people = result && (result.direct ? result.people : visiblePeople(result.people, blocked))
  const notes = result && visibleNotes(result.notes, blocked)
  return (
    <main class="screen">
      <header class="screen-head"><h2>Search</h2></header>
      <form class="search-form" onSubmit={submit}>
        <label class="field">
          <span>People and notes, or paste an npub</span>
          <input type="search" value={text} onInput={e => setText(e.currentTarget.value)} placeholder="Search Nostr" enterkeyhint="search" autocapitalize="off" autocorrect="off" spellcheck={false} />
        </label>
      </form>
      {status && <div class="status-line">{status}</div>}
      {result && !people.length && !notes.length && <p class="empty">Nothing found.</p>}
      {people?.length > 0 && <>
        <div class="section-label">People</div>
        {people.map(pk => <PersonRow key={pk} pubkey={pk} onClick={onProfile && (() => onProfile(pk))} />)}
      </>}
      {notes?.length > 0 && <>
        <div class="section-label">Notes</div>
        {notes.map(n => <NoteCard key={n.id} event={n} />)}
      </>}
    </main>
  )
}

function PersonRow({ pubkey, onClick }) {
  const p = useProfile(pubkey)
  const npub = npubEncode(pubkey)
  const Row = onClick ? "button" : "div" // a button that does nothing is worse than none
  return (
    <Row type={onClick && "button"} class="person-row" onClick={onClick}>
      <Avatar pubkey={pubkey} />
      <span class="person-names">
        <span class="author-name">{p?.name || npub.slice(0, 16) + "…"}</span>
        <span class="person-sub">{p?.nip05?.replace(/^_@/, "") || npub.slice(0, 12) + "…" + npub.slice(-6)}</span>
      </span>
    </Row>
  )
}
