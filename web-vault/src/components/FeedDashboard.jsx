// The Feed Dashboard (parity #19), the iPhone's FeedDashboardView: a sheet over the Feed, opened from the feed menu's
// Dashboard. "Your network, last 24 hours": four stats, Live now, Most active today, Popular with your people, Trending in
// your circle, From your follows, then Your vault. A stat or a tile opens its feed on Following, since the dashboard is
// about the people you follow. Read only: the load (net/feed-dashboard.js) saves nothing.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "./Avatar.jsx"
import { useAutoLook } from "./auto-look.js"
import { AuthorName } from "./NoteCard.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { readLists, followersOf } from "../net/vault-lists.js"
import { globalTrust } from "../readers/trust.js"
import { savePollScope } from "../readers/polls.js"
import { saveScope as saveMarketScope } from "../readers/market.js"
import { saveScope as saveRecipeScope } from "../readers/recipes.js"
import { saveScope as saveLiveScope } from "../readers/live.js"
import { saveScope as saveReelScope } from "../readers/reels.js"
import { TILE_NAMES, WINDOW_S, compact, fetchDashboard, newFollowersSince, profilesOf } from "../net/feed-dashboard.js"
import { countEvents } from "../net/feed-dashboard-vault.js"

if (import.meta.env) import("../styles/feed-dashboard.css")

const STALE_MS = 5 * 60_000
// Kept for the page's life, per account, as the iPhone reuses its snapshot for a few minutes.
const kept = { key: null, at: 0, snapshot: null }

/** Where each tile's feed keeps its Following / Global choice (FeedDashboardStore.openOnFollowing). */
const FOLLOWING_SCOPE = { polls: () => savePollScope("following"), marketplace: () => saveMarketScope("following"),
  recipes: () => saveRecipeScope("following"), live: () => saveLiveScope("following"), reels: () => saveReelScope("following") }
/** Opens `feed` on Following. */
export function openOnFollowing(feed, onPick) {
  FOLLOWING_SCOPE[feed]?.()
  onPick({ mode: feed })
  return true
}

const I = {
  posts: "M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z", people: "M16 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M9 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM22 19v-1a4 4 0 0 0-3-3.9M16 3.1a3.5 3.5 0 0 1 0 6.8",
  bolt: "M13 2 4 14h7l-1 8 9-12h-7z", follower: "M15 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M8.5 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM19 8v6M22 11h-6",
  live: "M12 12h.01M8.5 15.5a5 5 0 0 1 0-7M15.5 8.5a5 5 0 0 1 0 7M5.6 18.4a9 9 0 0 1 0-12.8M18.4 5.6a9 9 0 0 1 0 12.8",
  chart: "M4 20V10M10 20V4M16 20v-7M22 20H2", flame: "M12 22c4 0 7-3 7-7 0-4-3-6-4-9-1 2-2 3-4 3 0-2-1-4-3-6-1 4-5 6-5 12 0 4 3 7 9 7z",
  hash: "M4 9h16M4 15h16M10 3 8 21M16 3l-2 18", grid: "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z",
  shield: "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z", heart: "M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z",
  eye: "M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", more: "M9 6l6 6-6 6",
}
const Icon = ({ d, size = 16 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

export function FeedDashboard({ ctx, blocked = new Set(), onPick, onClose }) {
  const me = ctx.session?.pubkey, follows = ctx.account.follows, read = ctx.account.relays.read
  const key = `${me}:${follows.length}`
  const [snap, setSnap] = useState(() => (kept.key === key ? kept.snapshot : null))
  const [loading, setLoading] = useState(false)
  const [vault, setVault] = useState({ events: null, wot: 0 })
  const seq = useRef(0)
  const box = useRef(null)

  const load = async () => {
    const n = ++seq.current
    setLoading(true)
    try {
      const now = Math.floor(Date.now() / 1000)
      const newFollowers = newFollowersSince(followersOf(readLists(me), me, blocked), now - WINDOW_S)
      const s = await fetchDashboard({ follows, owner: me, readRelays: read, blocked, newFollowers, now, ctx })
      if (n !== seq.current) return
      Object.assign(kept, { key, at: Date.now(), snapshot: s })
      setSnap(s)
      const pks = profilesOf(s)
      if (pks.length) fetchProfiles(ctx.vault, pks, read, { save: false }).catch(() => {})
    } catch {} finally { if (n === seq.current) setLoading(false) }
  }
  useEffect(() => {
    if (follows.length && !(kept.key === key && Date.now() - kept.at < STALE_MS)) load()
    countEvents(ctx.vault).then(events => setVault(v => ({ ...v, events }))).catch(() => {})
    globalTrust(me, follows).then(t => setVault(v => ({ ...v, wot: t?.size ?? 0 }))).catch(() => {})
  }, [key])
  // Looks again on its own while open, as every screen does (no Refresh button, Logen 2026-11-04).
  useAutoLook(() => { if (follows.length && !loading) return load() }, { every: STALE_MS, on: follows.length > 0 }, [key])
  useEffect(() => {
    box.current?.querySelector(".fdash-done")?.focus()
    const esc = e => { if (e.key === "Escape") onClose() }
    addEventListener("keydown", esc)
    return () => removeEventListener("keydown", esc)
  }, [])

  const feed = f => { if (openOnFollowing(f, onPick)) onClose() }
  const go = href => { onClose(); location.hash = href }
  return (
    <div class="fdash-backdrop" onClick={onClose}>
      <div class="fdash" role="dialog" aria-modal="true" aria-labelledby="fdash-title" ref={box} onClick={e => e.stopPropagation()}>
        <header class="fdash-head">
          <span aria-hidden="true" />
          <div class="fdash-title">
            <strong id="fdash-title">Dashboard</strong>
            <span>{loading ? "Updating…" : "Your network, last 24 hours"}</span>
          </div>
          <button type="button" class="fdash-done" onClick={onClose}>Done</button>
        </header>
        <div class="fdash-body">
          {!follows.length ? <Empty text="Follow some people and their day shows up here." />
            : !snap ? <p class="fdash-loading" role="status"><span class="spinner" aria-hidden="true" />Looking at your network's last 24 hours…</p>
            : <Content s={snap} feed={feed} go={go} onPick={onPick} onClose={onClose} />}
          <button type="button" class="fdash-card fdash-vault" onClick={() => go("#/vault")}>
            <span class="fdash-accent"><Icon d={I.shield} size={20} /></span>
            <span class="fdash-vault-text"><strong>Your vault</strong><span>{vaultLine(vault)}</span></span>
            <Icon d={I.more} />
          </button>
        </div>
      </div>
    </div>
  )
}

/** "12.3k events · Web of Trust 1.2k"; the events part waits for the count, the web part for the web. */
export function vaultLine({ events, wot }) {
  const parts = [events == null ? "Counting events…" : `${compact(events)} events`]
  if (wot > 0) parts.push(`Web of Trust ${compact(wot)}`)
  return parts.join(" · ")
}

function Content({ s, feed, go, onPick, onClose }) {
  return <>
    <div class="fdash-stats">
      <Stat value={s.posts} label={s.posts === 1 ? "post" : "posts"} icon={I.posts} tint="blue" onClick={() => feed("following")} />
      <Stat value={s.activePeople} label="people posted" icon={I.people} tint="green" onClick={() => feed("following")} />
      <Stat value={s.satsReceived} label="sats to you" icon={I.bolt} tint="gold" onClick={() => go("#/vault/zaps")} />
      <Stat value={s.newFollowers} label={s.newFollowers === 1 ? "new follower" : "new followers"} prefix={s.newFollowers > 0 ? "+" : ""}
        icon={I.follower} tint="purple" onClick={() => go("#/vault/followers")} />
    </div>
    {s.live.length > 0 && <Card title="Live now" trailing={String(s.live.length)} icon={I.live} tint="red" onMore={() => feed("live")}>
      {s.live.slice(0, 3).map(l => (
        <button key={l.address} type="button" class="fdash-row" onClick={() => feed("live")}>
          <Avatar pubkey={l.host} size={36} />
          <span class="fdash-row-text"><strong>{l.title || "Live stream"}</strong><span><AuthorName pubkey={l.host} /></span></span>
          {l.viewers > 0 && <span class="fdash-meta"><Icon d={I.eye} size={13} />{l.viewers}</span>}
        </button>
      ))}
    </Card>}
    {s.mostActive.length > 0 && <Card title="Most active today" icon={I.chart} tint="green" onMore={() => feed("following")}>
      <MostActive people={s.mostActive} go={go} />
    </Card>}
    {s.popular.length > 0 && <Card title="Popular with your people" icon={I.flame} tint="orange">
      {s.popular.map((p, i) => (
        <button key={p.id} type="button" class="fdash-row fdash-popular" onClick={() => go(`#/thread/${p.id}`)}>
          <span class="fdash-rank">{i + 1}</span>
          <Avatar pubkey={p.note.pubkey} size={28} />
          <span class="fdash-row-text">
            <strong><AuthorName pubkey={p.note.pubkey} /></strong>
            <span class="fdash-clip">{p.note.content}</span>
            <span class="fdash-meta"><Icon d={I.heart} size={12} />{p.people} of your follows</span>
          </span>
        </button>
      ))}
    </Card>}
    {s.trending.length > 0 && <Card title="Trending in your circle" icon={I.hash} tint="blue">
      <div class="fdash-chips">
        {s.trending.map(t => (
          <button key={t.id} type="button" class="fdash-chip" aria-label={`#${t.id}, ${t.count} people`}
            onClick={() => { onPick({ mode: "hashtag", tag: t.id }); onClose() }}>#{t.id} <span>{t.count}</span></button>
        ))}
      </div>
    </Card>}
    {s.tiles.length > 0 && <Card title="From your follows" icon={I.grid} tint="purple">
      <div class="fdash-tiles">
        {s.tiles.map(t => (
          <button key={t.feed} type="button" class="fdash-tile" aria-label={`${TILE_NAMES[t.feed]}, ${t.count}`} onClick={() => feed(t.feed)}>
            <span class="fdash-tile-count">{t.count}</span>
            <strong>{TILE_NAMES[t.feed]}</strong>
            <span class="fdash-clip">{t.preview ?? " "}</span>
          </button>
        ))}
      </div>
    </Card>}
  </>
}

function Stat({ value, label, icon, tint, prefix = "", onClick }) {
  return (
    <button type="button" class={`fdash-stat tint-${tint}`} onClick={onClick}>
      <Icon d={icon} />
      <span class="fdash-stat-value">{prefix}{compact(value)}</span>
      <span class="fdash-stat-label">{label}</span>
    </button>
  )
}

function Card({ title, trailing, icon, tint, onMore, children }) {
  return (
    <section class="fdash-card">
      <h3 class="fdash-card-head">
        <span class={`tint-${tint}`}><Icon d={icon} /></span>{title}
        {trailing && <span class="fdash-trailing">{trailing}</span>}
        {onMore && <button type="button" class="fdash-more" aria-label={`Open ${title}`} onClick={onMore}><Icon d={I.more} size={14} /></button>}
      </h3>
      {children}
    </section>
  )
}

/** Faces of the most active, 6 on a phone and 12 on a wide sheet, then "+N". */
function MostActive({ people, go }) {
  const wide = globalThis.matchMedia?.("(min-width: 700px)").matches
  const shown = people.slice(0, wide ? 12 : 6)
  return (
    <div class="fdash-faces">
      {shown.map(p => (
        <button key={p.id} type="button" class="fdash-face" onClick={() => go(`#/profile/${p.id}`)} title={`${p.count} posts`}
          aria-label={`${p.count} posts`}><Avatar pubkey={p.id} size={40} /></button>
      ))}
      {people.length > shown.length && <span class="fdash-more-count">+{people.length - shown.length}</span>}
    </div>
  )
}

function Empty({ text }) {
  return <div class="fdash-empty"><Icon d={I.people} size={28} /><p>{text}</p></div>
}
