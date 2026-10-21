// What Search shows before anything is typed, as the iPhone's (Views/Search/SearchView+EmptyState.swift): Recent
// searches with Clear, Trending hashtags and the people Active in your feed (both from the notes Haven holds), and
// the "Search" hint when there is none of those.
import { useEffect, useState } from "preact/hooks"
import { activePosters, trendingTags } from "../net/search.js"
import { PersonRow } from "./SearchScreen.jsx"
import { useProfile } from "../components/useProfile.js"
import { fetchProfiles } from "../net/profiles.js"

const FEED_SAMPLE = 300 // the newest notes on hand that Trending and Active are counted from

export function SearchStart({ ctx, recent, onPick, onClearRecent, onProfile, blocked }) {
  const [notes, setNotes] = useState([])
  useEffect(() => {
    let live = true
    ctx.vault.feed.query({ kinds: [1], limit: FEED_SAMPLE }).then(evs => {
      if (!live) return
      setNotes(evs)
      fetchProfiles(ctx.vault, activePosters(evs, ctx.session.pubkey), ctx.account.relays.read).catch(() => {}) // names for Active
    }).catch(() => {})
    return () => { live = false }
  }, [])
  const trending = trendingTags(notes)
  const active = activePosters(notes, ctx.session.pubkey, blocked)

  if (!recent.length && !trending.length && !active.length) return (
    <div class="empty">
      <p><b>Search</b></p>
      <p>Find users, notes, hashtags and links<br />Or paste a note1 or nevent1 ID</p>
    </div>
  )
  return (
    <>
      {recent.length > 0 && <>
        <div class="vault-search-head section-label"><span>Recent</span><button type="button" class="link" onClick={onClearRecent}>Clear</button></div>
        <div class="chips">{recent.map(q => <button key={q} type="button" class="chip" onClick={() => onPick(q)}>{q}</button>)}</div>
      </>}
      {trending.length > 0 && <>
        <div class="section-label">Trending</div>
        <div class="chips">{trending.map(t => <button key={t} type="button" class="chip" onClick={() => onPick(`#${t}`)}>#{t}</button>)}</div>
      </>}
      {active.length > 0 && <>
        <div class="section-label">Active in your feed</div>
        {active.map(pk => <ActiveRow key={pk} pubkey={pk} onProfile={onProfile} />)}
      </>}
    </>
  )
}

// Only people with a name, as the iPhone's list: a bare npub tells you nothing about who is active.
function ActiveRow({ pubkey, onProfile }) {
  const p = useProfile(pubkey)
  if (!p?.name && !p?.display_name) return null
  return <PersonRow pubkey={pubkey} onClick={onProfile && (() => onProfile(pubkey))} />
}
