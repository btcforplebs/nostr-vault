// Search, as the iPhone's Search tab (Views/Search): an icon pill of result tabs and a filter circle (Who and When,
// SearchFilterMenu) over the field. Results come as you type (300 ms after the last key, 2
// characters or more) in Users / Notes / Hashtags / Links, narrowed by Who and When without asking again, ranked you ->
// people you follow -> everyone. Before anything is typed it shows Recent, Trending and Active (SearchStart.jsx).
// A pasted npub / nprofile / hex pubkey shows that one profile (Return opens it); a note1 / nevent opens the note;
// "#tag" + Return opens the tag's feed. People and notes come from the NIP-50 search relays (net/search.js).
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { NoteCard } from "../components/NoteCard.jsx"
import { useProfile } from "../components/useProfile.js"
import { SearchStart } from "./SearchStart.jsx"
import { parseQuery, hashtagOf, searchNostr, shapeResults, filterCaption, loadRecent, saveRecent, clearRecent, MIN_QUERY, NO_FILTER, WHO, WHEN } from "../net/search.js"
import { fetchProfiles, putProfile } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { visibleNotes, visiblePeople } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { SkeletonList, Spinner } from "../components/Loading.jsx"

const SEARCHING = "Searching…"

const DEBOUNCE_MS = 300
const TABS = [ // SearchView's tab symbols: square.grid.2x2, person.2, doc.text, number, link
  { id: "all", label: "All", icon: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z" },
  { id: "users", label: "Users", icon: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8" },
  { id: "notes", label: "Notes", icon: "M4 4h16v16H4zM8 9h8M8 13h8M8 17h5" },
  { id: "hashtags", label: "Hashtags", icon: "M10 3L8 21M16 3l-2 18M4 8.5h16M3.5 15.5h16" },
  { id: "links", label: "Links", icon: "M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1" },
]
const FUNNEL = "M4 6h16M7 12h10M10 18h4"
const GLASS = "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM21 21l-5-5"
const Icon = ({ d, size = 18 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
const storage = () => globalThis.localStorage
const hostOf = url => { try { return new URL(url).hostname } catch { return "" } }

export function SearchScreen({ ctx, onProfile }) {
  const [text, setText] = useState("")
  const [found, setFound] = useState(null) // null | { people: [pubkey], notes: [event], direct? } as the relays answered
  const [status, setStatus] = useState("")
  const [tab, setTab] = useState("all")
  const [filter, setFilter] = useState(NO_FILTER)
  const [recent, setRecent] = useState(() => loadRecent(storage()))
  const seq = useRef(0) // a slow answer to an older query must not replace a newer one
  const { blocked } = useBlocks(ctx)
  const openNote = id => { location.hash = `#/thread/${id}` } // the thread screen fetches a note Haven lacks

  const run = async (input, n) => {
    const q = parseQuery(input)
    if (q.type === "empty") { setFound(null); setStatus(""); return }
    if (q.type === "profile") {
      setFound({ people: [q.pubkey], notes: [], direct: true }); setStatus("")
      fetchProfiles(ctx.vault, [q.pubkey], uniq([...q.relays, ...ctx.account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
      return
    }
    if (q.type === "note") { setFound(null); setStatus(""); openNote(q.id); return }
    if (q.text.length < MIN_QUERY) { setFound(null); setStatus(""); return }
    if (!navigator.onLine) { setStatus("Offline: search needs the network"); return }
    setStatus(SEARCHING)
    setRecent(saveRecent(storage(), q.text))
    try {
      const { people, notes } = await searchNostr(q.text)
      if (n !== seq.current) return
      people.forEach(putProfile)
      setFound({ people: people.map(ev => ev.pubkey), notes })
      fetchProfiles(ctx.vault, notes.map(ev => ev.pubkey), ctx.account.relays.read).catch(() => {})
      setStatus("")
    } catch (err) {
      if (n === seq.current) setStatus(`Search failed (${err?.message ?? err})`)
    }
  }

  // Live: each keystroke restarts the wait; emptying the box clears at once.
  useEffect(() => {
    const n = ++seq.current
    if (!text.trim()) { setFound(null); setStatus(""); setTab("all"); return }
    const t = setTimeout(() => run(text, n), DEBOUNCE_MS)
    return () => clearTimeout(t)
  }, [text])

  // Return: no waiting. "#tag" opens its feed and a pasted profile opens it; anything else searches now.
  const submit = e => {
    e.preventDefault()
    const tag = hashtagOf(text)
    if (tag) { location.hash = `#/feed?tag=${encodeURIComponent(tag)}`; return }
    const q = parseQuery(text)
    if (q.type === "profile") { onProfile?.(q.pubkey); return }
    run(text, ++seq.current)
  }
  const clear = () => { ++seq.current; setText(""); setFound(null); setStatus(""); setTab("all") }

  // A pasted npub still shows that profile, blocked or not: that is the way to find someone to unblock them.
  const shown = found && shapeResults({
    people: found.direct ? found.people : visiblePeople(found.people, blocked),
    notes: visibleNotes(found.notes, blocked),
  }, text, { me: ctx.session.pubkey, follows: ctx.account.follows, filter: found.direct ? NO_FILTER : filter })
  const count = shown && { users: shown.people.length, notes: shown.notes.length, hashtags: shown.hashtags.length, links: shown.links.length }
  const any = count && Object.values(count).some(Boolean)
  const show = id => (tab === "all" || tab === id) && count[id] > 0
  const caption = filterCaption(filter)
  const filteredOut = found && !found.direct && (found.people.length || found.notes.length)
  return (
    <main class="screen search">
      <header class="screen-head search-head">
        <div class="search-tabs" role="tablist" aria-label="Results">
          {TABS.map(t => <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} class={tab === t.id ? "on" : ""} aria-label={t.label} title={t.label} onClick={() => setTab(t.id)}><Icon d={t.icon} /></button>)}
        </div>
        <FilterMenu filter={filter} setFilter={setFilter} caption={caption} />
      </header>
      <form class="search-form" onSubmit={submit}>
        <label class="search-field">
          <Icon d={GLASS} />
          <input type="search" aria-label="Users, notes, hashtags and links, or paste an npub" value={text} onInput={e => setText(e.currentTarget.value)} onKeyDown={e => e.key === "Escape" && text && (e.preventDefault(), clear())}
            placeholder="Search users, notes, hashtags..." enterkeyhint="search" autocapitalize="off" autocorrect="off" spellcheck={false} />
        </label>
      </form>
      {!text.trim() && <SearchStart ctx={ctx} recent={recent} blocked={blocked} onPick={setText} onProfile={onProfile} onClearRecent={() => setRecent(clearRecent(storage()))} />}
      {text.trim() && found && !found.direct && caption && <div class="vault-search-head section-label"><span>{caption}</span><button type="button" class="link" onClick={() => setFilter(NO_FILTER)}>Clear filter</button></div>}
      {status && <div class="status-line">{status === SEARCHING && <Spinner />} {status}</div>}
      {status === SEARCHING && !found && <SkeletonList count={5} rowClass="person-row" label={SEARCHING} />}
      {shown && !any && !status && <div class="empty">
        <p>No results found</p>
        {caption && filteredOut && <button type="button" class="small" onClick={() => setFilter(NO_FILTER)}>Clear filter</button>}
      </div>}
      {shown && any && <>
        {show("users") && <>
          <div class="section-label">Users</div>
          {shown.people.map(pk => <PersonRow key={pk} pubkey={pk} onClick={onProfile && (() => onProfile(pk))} />)}
        </>}
        {show("notes") && <>
          <div class="section-label">Notes</div>
          {shown.notes.map(n => <NoteCard key={n.id} event={n} />)}
        </>}
        {show("hashtags") && <>
          <div class="section-label">Hashtags</div>
          <div class="chips">{shown.hashtags.map(t => <a key={t} class="chip" href={`#/feed?tag=${encodeURIComponent(t)}`}>#{t}</a>)}</div>
        </>}
        {show("links") && <>
          <div class="section-label">Links</div>
          {shown.links.map(l => <a key={l.url} class="person-row" href={l.url} target="_blank" rel="noopener noreferrer">
            <span class="person-names"><span class="author-name">{l.title}</span><span class="person-sub">{hostOf(l.url)}</span></span>
          </a>)}
        </>}
        {tab !== "all" && !count[tab] && <div class="empty">
          <p>No {TABS.find(t => t.id === tab).label.toLowerCase()} matched “{text.trim()}”</p>
          <p>Other tabs have results.</p>
        </div>}
      </>}
    </main>
  )
}

/** The top-right filter circle: Who and When in one list that stays open while both are set (SearchFilterMenu).
 *  A filled accent funnel while anything is on; the caption under the field says what. */
function FilterMenu({ filter, setFilter, caption }) {
  const [open, setOpen] = useState(false)
  const ref = useRef()
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  return (
    <div class="vault-menu right" ref={ref}>
      <button type="button" class={`vault-pill-btn search-filter-btn ${caption ? "on" : ""}`} aria-haspopup="true" aria-expanded={open} aria-label="Filter" title={caption || "Filter"} onClick={() => setOpen(!open)}><Icon d={FUNNEL} /></button>
      {open && <div class="vault-menu-list search-filter-list">
        <div class="section-label">Who</div>
        <div class="vault-search-chips" role="group" aria-label="Who">
          {WHO.map(w => <button key={w.id} type="button" class={filter.who === w.id ? "chip on" : "chip"} aria-pressed={filter.who === w.id} onClick={() => setFilter(f => ({ ...f, who: w.id }))}>{w.label}</button>)}
        </div>
        <div class="section-label">When</div>
        <div class="vault-search-chips" role="group" aria-label="When">
          {WHEN.map(w => <button key={w.id} type="button" class={filter.when === w.id ? "chip on" : "chip"} aria-pressed={filter.when === w.id} onClick={() => setFilter(f => ({ ...f, when: w.id }))}>{w.label}</button>)}
        </div>
        {caption && <button type="button" class="small" onClick={() => setFilter(NO_FILTER)}>Clear filter</button>}
      </div>}
    </div>
  )
}

export function PersonRow({ pubkey, onClick }) {
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
