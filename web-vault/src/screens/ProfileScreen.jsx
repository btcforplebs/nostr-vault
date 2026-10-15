// The user's profile: notes and articles, read from Haven's outbox route after a network backfill into it.
import { useEffect, useState } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { readOwn, syncOwn } from "../net/sync.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"

const GEAR = "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
const Icon = ({ d, fill }) => <svg viewBox="0 0 24 24" width="18" height="18" fill={fill ? "currentColor" : "none"} stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

export function ProfileScreen({ ctx }) {
  const { vault, account, session } = ctx
  const [tab, setTab] = useState("notes")
  const [notes, setNotes] = useState([])
  const [articles, setArticles] = useState([])

  const reload = async () => {
    setNotes(await readOwn(vault, session.pubkey, [1]))
    setArticles(await readOwn(vault, session.pubkey, [30023], 50))
  }
  useEffect(() => {
    reload().then(() => navigator.onLine && syncOwn(vault, session.pubkey, uniq([...account.relays.write, ...DEFAULT_RELAYS]))).then(reload).catch(() => {})
  }, [])

  return (
    <main class="screen">
      {/* The phone's Profile toolbar: the Wallet on the left, Settings on the right, floating over the banner. */}
      <header class="screen-head profile-hud">
        <a class="vault-pill-btn hud-accent" href="#/wallet" aria-label="Wallet" title="Wallet"><Icon d="M13 2L4 14h7l-1 8 9-12h-7z" fill /></a>
        <a class="vault-pill-btn" href="#/settings" aria-label="Settings" title="Settings"><Icon d={GEAR} /></a>
      </header>
      <ProfileHeader pubkey={session.pubkey} follows={account.follows.length} />
      <div class="segmented">
        <button class={tab === "notes" ? "on" : ""} onClick={() => setTab("notes")}>Notes</button>
        <button class={tab === "articles" ? "on" : ""} onClick={() => setTab("articles")}>Articles</button>
      </div>
      {tab === "notes"
        ? (notes.length ? notes.map(n => <NoteCard key={n.id} event={n} />) : <p class="empty">No notes yet.</p>)
        : (articles.length ? articles.map(a => <ArticleCard key={a.id} event={a} />) : <p class="empty">No articles yet.</p>)}
    </main>
  )
}
