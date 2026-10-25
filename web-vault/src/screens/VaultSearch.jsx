// The Vault's search (iPhone VaultSearchBar + VaultSearchResults): a field over the Vault's list that searches this
// browser's relay, with All / People / Notes / Articles / Media / Hashtags / Links chips. "All" shows a few of each
// with "See all"; a hashtag opens its feed; a link opens, and its note is a tap away.
import { useEffect, useRef, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName, NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useProfile } from "../components/useProfile.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { SECTIONS, searchVault, terms } from "../net/vault-search.js"
import { Spinner } from "../components/Loading.jsx"

/** Rows per section under "All", and rows in one section: the relay walk keeps every match, and the cap keeps a
 *  common word from building thousands of rows (VaultSearchResults.preview / sectionCap). */
export const PREVIEW = 5
export const SECTION_CAP = 200

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
          placeholder="Search your Vault" aria-label="Search your Vault" enterkeyhint="search" autocapitalize="off" autocorrect="off" spellcheck={false} />
        <button type="button" class="small" onClick={onClose}>Done</button>
      </form>
      {found && total > 0 && (
        <div class="vault-search-chips" role="tablist" aria-label="Results">
          <Chip on={section === "all"} onClick={() => setSection("all")}>All {total}</Chip>
          {SECTIONS.filter(s => counts[s.id]).map(s => <Chip key={s.id} on={section === s.id} onClick={() => setSection(s.id)}>{s.title} {counts[s.id]}</Chip>)}
        </div>
      )}
      {busy && <div class="status-line"><Spinner /> Searching your Vault…</div>}
      {!busy && found?.cut && <div class="status-line">Your Vault has more matches than shown, so older items may be missing. Add a word to narrow it.</div>}
      {!found ? (text.trim().length === 1 ? <p class="empty">Type at least two letters.</p>
          : <Message title="Search your Vault" detail="Notes, people, hashtags, links, articles and media stored in this browser's relay." />)
        : total === 0 ? <Message title="Nothing in your Vault matches" detail={`“${found.query}”`} />
        : shown.map(s => {
          const all = found[s.id]
          const list = section === "all" ? all.slice(0, PREVIEW) : all.slice(0, SECTION_CAP)
          return (
            <section key={s.id} class="vault-search-section">
              <div class="section-label vault-search-head"><span>{s.title}</span>{section === "all" && all.length > PREVIEW && <button class="link" onClick={() => setSection(s.id)}>See all {all.length}</button>}</div>
              {list.map(item => <Row key={item.id ?? item.url ?? item} kind={s.id} item={item} trusted={trusted} />)}
              {section !== "all" && all.length > SECTION_CAP && <p class="muted small">Showing the newest {SECTION_CAP} of {all.length}.</p>}
            </section>
          )
        })}
    </div>
  )
}

const Message = ({ title, detail }) => <div class="empty"><p><strong>{title}</strong></p><p class="muted small">{detail}</p></div>

const Chip = ({ on, onClick, children }) => <button role="tab" aria-selected={on} class={`chip ${on ? "on" : ""}`} onClick={onClick}>{children}</button>

/** A hashtag opens that tag's feed, as a #tag in a note does (NoteText). */
export const hashtagHref = tag => `#/feed?tag=${encodeURIComponent(String(tag).toLowerCase())}`

/** A person found: name, NIP-05 and two lines of about (VaultSearchPersonRow). */
function PersonHit({ pubkey, trusted }) {
  const p = useProfile(pubkey)
  const nip05 = typeof p?.nip05 === "string" ? p.nip05.replace(/^_@/, "") : ""
  const about = typeof p?.about === "string" ? p.about.trim() : ""
  return (
    <a class="person-row" href={`#/profile/${pubkey}`}>
      <Avatar pubkey={pubkey} size={40} load={trusted(pubkey)} />
      <span class="person-names"><AuthorName pubkey={pubkey} />{nip05 && <span class="person-sub">{nip05}</span>}{about && <span class="person-sub vault-search-about">{about}</span>}</span>
    </a>
  )
}

export function Row({ kind, item, trusted }) {
  switch (kind) {
    case "people": return <PersonHit pubkey={item} trusted={trusted} />
    case "articles": return <ArticleCard event={item} />
    case "notes": case "media": return <NoteCard event={item} />
    case "hashtags": return <a class="settings-row vault-search-row" href={hashtagHref(item)}><span class="settings-title">#{item}</span></a>
    case "links": return (
      <div class="settings-row vault-search-row">
        <a class="settings-title" href={item.url} target="_blank" rel="noopener noreferrer" title={item.url}>{item.title}</a>
        <a class="small" href={`#/thread/${item.noteId}`}>Note</a>
      </div>
    )
    default: return null
  }
}
