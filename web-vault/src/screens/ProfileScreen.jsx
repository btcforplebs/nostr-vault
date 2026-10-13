// The user's profile: notes and articles, read from Haven's outbox route after a network backfill into it.
import { useEffect, useState } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { NoteCard } from "../components/NoteCard.jsx"
import { readOwn, syncOwn } from "../net/sync.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { ago } from "../components/time.js"

export function ProfileScreen({ ctx }) {
  const { vault, account, session } = ctx
  const [tab, setTab] = useState("notes")
  const [notes, setNotes] = useState([])
  const [articles, setArticles] = useState([])
  const [open, setOpen] = useState(null)

  const reload = async () => {
    setNotes(await readOwn(vault, session.pubkey, [1]))
    setArticles(await readOwn(vault, session.pubkey, [30023], 50))
  }
  useEffect(() => {
    reload().then(() => navigator.onLine && syncOwn(vault, session.pubkey, uniq([...account.relays.write, ...DEFAULT_RELAYS]))).then(reload).catch(() => {})
  }, [])

  return (
    <main class="screen">
      <ProfileHeader pubkey={session.pubkey} follows={account.follows.length} />
      <div class="segmented">
        <button class={tab === "notes" ? "on" : ""} onClick={() => setTab("notes")}>Notes</button>
        <button class={tab === "articles" ? "on" : ""} onClick={() => setTab("articles")}>Articles</button>
      </div>
      {tab === "notes"
        ? (notes.length ? notes.map(n => <NoteCard key={n.id} event={n} />) : <p class="empty">No notes yet.</p>)
        : (articles.length ? articles.map(a => {
            const tag = k => a.tags.find(t => t[0] === k)?.[1]
            return (
              <article key={a.id} class="article" onClick={() => setOpen(open === a.id ? null : a.id)}>
                {tag("image") && <img class="article-image" src={tag("image")} alt="" loading="lazy" />}
                <h3>{tag("title") || "Untitled"}</h3>
                <div class="muted">{ago(Number(tag("published_at")) || a.created_at)}</div>
                {open === a.id ? <div class="article-body">{a.content}</div> : tag("summary") && <p>{tag("summary")}</p>}
              </article>
            )
          }) : <p class="empty">No articles yet.</p>)}
    </main>
  )
}
