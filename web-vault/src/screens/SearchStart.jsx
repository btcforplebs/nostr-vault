// What Search shows before anything is typed, as the iPhone's (Views/Search/SearchView+EmptyState.swift): Recent
// searches with Clear, For you (people your follows follow, your topics, notes picked from them: net/for-you.js),
// Trending hashtags and the people Active in your feed (both from the notes Haven holds), and the "Search" hint when
// there is none of those.
import { useEffect, useState } from "preact/hooks"
import { activePosters, trendingTags } from "../net/search.js"
import { PersonRow } from "./SearchScreen.jsx"
import { Avatar } from "../components/Avatar.jsx"
import { NoteCard } from "../components/NoteCard.jsx"
import { useProfile } from "../components/useProfile.js"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { followLists } from "../net/wot.js"
import { latestList } from "../net/list-edit.js"
import { followedTags, interests, pickedNotes, reactedIds, recommendedPeople, vouchesFrom } from "../net/for-you.js"
import "../styles/search-for-you.css"

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
  const forYou = useForYou(ctx, notes, blocked)
  const hasForYou = forYou.people.length || forYou.topics.length || forYou.notes.length

  if (!recent.length && !hasForYou && !trending.length && !active.length) return (
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
      {hasForYou > 0 && <ForYou {...forYou} onProfile={onProfile} />}
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

/** For you's inputs, gathered as the iPhone's refreshRecommendations: the follows' lists (vouches), the kind 10015,
 *  your reactions and own notes (what you engage with), and the feed notes on hand. Each part shows as it arrives. */
function useForYou(ctx, notes, blocked) {
  const me = ctx.session.pubkey
  const follows = ctx.account.follows
  const [vouches, setVouches] = useState(new Map())
  const [followed, setFollowed] = useState([])
  const [mine, setMine] = useState({ own: [], reacted: new Set() })
  const [, namesIn] = useState(0)
  useEffect(() => onProfiles(() => namesIn(n => n + 1)), [])
  useEffect(() => {
    let live = true
    followLists(me, follows).then(l => live && setVouches(vouchesFrom(follows, l))).catch(() => {})
    latestList(ctx, 10015).then(r => live && setFollowed(followedTags(r.event))).catch(() => {})
    Promise.all([
      ctx.vault.outbox.query({ kinds: [1], authors: [me], limit: 100 }).catch(() => []),
      ctx.vault.outbox.query({ kinds: [7], authors: [me], limit: 500 }).catch(() => []),
    ]).then(([own, likes]) => live && setMine({ own, reacted: reactedIds(likes) }))
    return () => { live = false }
  }, [me, follows.length])

  const following = new Set(follows)
  const wanted = recommendedPeople(vouches, { following, me, blocked })
  const people = wanted.filter(p => getProfile(p.pubkey)?.name) // the rest show once their names arrive
  const engaged = [...mine.own, ...notes.filter(n => n.pubkey === me || mine.reacted.has(n.id))].map(n => n.tags)
  const topics = interests(followed, engaged)
  const picked = pickedNotes(notes, { topics, following, vouches, me, blocked, seen: mine.reacted })
  const key = wanted.map(p => p.pubkey).join()
  useEffect(() => { if (wanted.length) fetchProfiles(ctx.vault, wanted.map(p => p.pubkey), ctx.account.relays.read).catch(() => {}) }, [key])
  return { people, topics, notes: picked }
}

// SearchRecommendationsSection: a people rail, a topic rail and the picked notes, under "For you".
function ForYou({ people, topics, notes, onProfile }) {
  return (
    <section class="for-you">
      <div class="section-label for-you-head">
        <span>For you</span>
        <span class="for-you-src" title="Picked in this browser from your follows' lists and the notes you have. No recommendation server is asked.">Ranked by your relay</span>
      </div>
      {people.length > 0 && <>
        <div class="for-you-sub">People you may know</div>
        <div class="for-you-rail">{people.map(p => <PersonCard key={p.pubkey} {...p} onProfile={onProfile} />)}</div>
      </>}
      {topics.length > 0 && <>
        <div class="for-you-sub">Your topics</div>
        <div class="for-you-rail">{topics.map(t => <a key={t} class="chip topic" href={`#/feed?tag=${encodeURIComponent(t)}`}>#{t}</a>)}</div>
      </>}
      {notes.length > 0 && <>
        <div class="for-you-sub">Picked from your topics</div>
        {notes.map(n => <NoteCard key={n.id} event={n} />)}
      </>}
    </section>
  )
}

// Only people with a name reach the rail (useForYou), as the iPhone's.
function PersonCard({ pubkey, vouches, onProfile }) {
  const p = useProfile(pubkey)
  return (
    <button type="button" class="for-you-card" onClick={() => onProfile?.(pubkey)} aria-label={`${p?.name}, followed by ${vouches} people you follow`}>
      <Avatar pubkey={pubkey} size={48} />
      <b>{p?.name}</b>
      <span>{vouches} of your follows</span>
    </button>
  )
}
