// The tab bar and list under a profile header (net/profile-tabs.js), shared by your profile and someone else's.
// `notes` are the profile's kind 1s, `articles` its kind 30023s; `more` is the footer under the notes tabs (Older
// notes on someone else's profile). `onTab` lets a screen fetch articles only when that tab is opened.
import { useMemo, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { PROFILE_TABS, splitProfileNotes, latestArticles } from "../net/profile-tabs.js"

if (import.meta.env) import("../styles/feeds.css")

const EMPTY = { notes: "No notes yet.", replies: "No replies yet.", media: "No photos or videos yet.", articles: "No articles yet." }

export function ProfileTabs({ notes, articles, empty = EMPTY, more = null, onTab }) {
  const [tab, setTab] = useState("notes")
  const split = useMemo(() => splitProfileNotes(notes ?? []), [notes])
  const arts = useMemo(() => (articles ? latestArticles(articles) : null), [articles])
  const pick = id => { setTab(id); onTab?.(id) }
  const msg = empty[tab] ?? EMPTY[tab]
  const list = tab === "media" ? split.media : tab === "articles" ? arts : split[tab]
  return (
    <>
      <div class="segmented profile-tabs" role="tablist" aria-label="Profile">
        {PROFILE_TABS.map(t => <button key={t.id} role="tab" aria-selected={tab === t.id} class={tab === t.id ? "on" : ""} onClick={() => pick(t.id)}>{t.label}</button>)}
      </div>
      {list === null ? <p class="empty">Fetching articles…</p>
        : !list.length ? (msg && <p class="empty">{msg}</p>)
        : tab === "media" ? <MediaGrid tiles={list} />
        : tab === "articles" ? list.map(a => <ArticleCard key={a.id} event={a} />)
        : list.map(n => <NoteCard key={n.id} event={n} />)}
      {tab !== "articles" && more}
    </>
  )
}
