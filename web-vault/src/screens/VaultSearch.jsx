// The Vault's search (iPhone VaultSearchBar + VaultSearchResults): a field over the Vault's list that searches this
// browser's relay, with All / People / Notes / Articles / Media / Hashtags / Links chips. "All" shows a few of each
// with "See all"; a hashtag searches for itself; a link opens, and its note is a tap away.
import { useEffect, useRef, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName, NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { SECTIONS, searchVault, terms } from "../net/vault-search.js"

const PREVIEW = 3

export function VaultSearch({ ctx, onClose }) {
  const { vault, account, session } = ctx
  const [text, setText] = useState("")
  const [found, setFound] = useState(null) // { query, ...results }
  const [busy, setBusy] = useState(false)
  const [section, setSection] = useState("all")
  const { blocked } = useBlocks(ctx)
  const live = useRef("")
  const input = useRef()
  useEffect(() => { input.current?.focus() }, [])

  const run = async q => {
    live.current = q
    if (!terms(q)) { setFound(null); setBusy(false); return }
    setBusy(true)
    const r = await searchVault([vault.outbox, vault.inbox, vault.feed], q, { follows: account.follows, blocked, decode }).catch(() => null)
    if (live.current !== q) return // the field has moved on
    setFound(r && { query: q, ...r }); setBusy(false); setSection("all")
    if (r?.people.length) fetchProfiles(vault, r.people.slice(0, 40), uniq([...account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
  }
  // A short pause, so typing doesn't walk the stores per key; Return searches at once.
  useEffect(() => { const t = setTimeout(() => run(text.trim()), 300); return () => clearTimeout(t) }, [text])
  const now = q => { setText(q); run(q.trim()) }

  const trusted = pk => pk === session.pubkey || account.follows.includes(pk)
  const counts = found ? Object.fromEntries(SECTIONS.map(s => [s.id, found[s.id].length])) : {}
  const total = found ? SECTIONS.reduce((n, s) => n + counts[s.id], 0) : 0
  const shown = section === "all" ? SECTIONS.filter(s => counts[s.id]) : SECTIONS.filter(s => s.id === section)

  return (
    <div class="vault-search">
      <form class="vault-search-bar" role="search" onSubmit={e => { e.preventDefault(); now(text) }}>
        <input ref={input} type="search" value={text} onInput={e => setText(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Escape") onClose() }}
          placeholder="Search your vault" aria-label="Search your vault" enterkeyhint="search" autocapitalize="off" autocorrect="off" spellcheck={false} />
        <button type="button" class="small" onClick={onClose}>Done</button>
      </form>
      {found && total > 0 && (
        <div class="vault-search-chips" role="tablist" aria-label="Results">
          <Chip on={section === "all"} onClick={() => setSection("all")}>All {total}</Chip>
          {SECTIONS.filter(s => counts[s.id]).map(s => <Chip key={s.id} on={section === s.id} onClick={() => setSection(s.id)}>{s.title} {counts[s.id]}</Chip>)}
        </div>
      )}
      {busy && <div class="status-line">Searching…</div>}
      {!busy && found?.cut && <div class="status-line">Showing the newest matches; there may be more. Add a word to narrow it.</div>}
      {!found ? <p class="empty">{text.trim().length === 1 ? "Type at least two letters." : "Search the people, notes, articles and media in your vault. Every word has to match."}</p>
        : total === 0 ? <p class="empty">Nothing in your vault matches “{found.query}”.</p>
        : shown.map(s => {
          const all = found[s.id]
          const list = section === "all" ? all.slice(0, PREVIEW) : all
          return (
            <section key={s.id} class="vault-search-section">
              <div class="section-label vault-search-head"><span>{s.title}</span>{section === "all" && all.length > PREVIEW && <button class="link" onClick={() => setSection(s.id)}>See all {all.length}</button>}</div>
              {list.map(item => <Row key={item.id ?? item.url ?? item} kind={s.id} item={item} trusted={trusted} onTag={t => now(`#${t}`)} />)}
            </section>
          )
        })}
    </div>
  )
}

const Chip = ({ on, onClick, children }) => <button role="tab" aria-selected={on} class={`chip ${on ? "on" : ""}`} onClick={onClick}>{children}</button>

function Row({ kind, item, trusted, onTag }) {
  switch (kind) {
    case "people": return <a class="person-row" href={`#/profile/${item}`}><Avatar pubkey={item} size={40} load={trusted(item)} /><span class="person-names"><AuthorName pubkey={item} /></span></a>
    case "articles": return <ArticleCard event={item} />
    case "notes": case "media": return <NoteCard event={item} />
    case "hashtags": return <button class="settings-row vault-search-row" onClick={() => onTag(item)}><span class="settings-title">#{item}</span></button>
    case "links": return (
      <div class="settings-row vault-search-row">
        <a class="settings-title" href={item.url} target="_blank" rel="noopener noreferrer" title={item.url}>{item.title}</a>
        <a class="small" href={`#/thread/${item.noteId}`}>Note</a>
      </div>
    )
    default: return null
  }
}
