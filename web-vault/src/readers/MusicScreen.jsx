// Music (the iPhone's MusicBrowserView, artist and album pages, and player): Wavlake's trending songs this week or
// month with their top artists and albums, search, an artist's albums and songs, an album's songs, and a player bar
// that keeps playing when you switch feeds. Your artists (played or opened) above Trending, and Following: the
// Wavlake artists among the people you follow. Songs by someone you blocked are left out (wavlake.js visibleTracks).
import { useEffect, useRef, useState } from "preact/hooks"
import { useBlocks } from "../components/useBlocks.js"
import { formatSats } from "../net/notifications.js"
import * as wl from "./wavlake.js"
import { current, onPlayer, playList, playerState, previous, next, toggle } from "./player.js"

if (import.meta.env) import("./readers.css")

export function MusicScreen({ ctx }) {
  const { blocked } = useBlocks(ctx)
  const [days, setDays] = useState(7) // 7, 30, or "following"
  const [tracks, setTracks] = useState(null)
  const [error, setError] = useState("")
  const [query, setQuery] = useState("")
  const [results, setResults] = useState(null)
  const [page, setPage] = useState(null) // { type: "artist", artist } | { type: "album", album }
  const seq = useRef(0), searchSeq = useRef(0) // apart, so a search can't drop Trending's answer

  const loadTrending = async () => {
    const n = ++seq.current
    setError("")
    if (days === "following") return
    try { const t = await wl.trending(days); if (n === seq.current) setTracks(t) }
    catch (e) { if (n === seq.current) { setTracks([]); setError(`Couldn't reach Wavlake (${e?.message ?? e})`) } }
  }
  useEffect(() => { setTracks(null); loadTrending() }, [days])

  // Search after a short pause in typing, as the iPhone does; an empty box goes back to Trending.
  useEffect(() => {
    const term = query.trim()
    if (!term) { searchSeq.current++; setResults(null); return }
    const n = ++searchSeq.current
    const t = setTimeout(async () => {
      try { const r = await wl.search(term); if (n === searchSeq.current) setResults(r) }
      catch (e) { if (n === searchSeq.current) { setResults([]); setError(`Search failed (${e?.message ?? e})`) } }
    }, 400)
    return () => clearTimeout(t)
  }, [query])

  const open = p => { if (p.type === "artist") wl.rememberRecent(p.artist); setPage(p); globalThis.scrollTo?.(0, 0) }
  const body = page?.type === "artist" ? <ArtistPage id={page.artist.id} seed={page.artist} blocked={blocked} onOpen={open} onBack={() => setPage(null)} />
    : page?.type === "album" ? <AlbumPage id={page.album.id} seed={page.album} blocked={blocked} onOpen={open} onBack={() => setPage(null)} />
    : results ? <SearchResults results={wl.visibleResults(results, blocked)} blocked={blocked} onOpen={open} />
    : days === "following" ? <Following follows={ctx.account.follows} loaded={ctx.account.loaded} blocked={blocked} onOpen={open} />
    : <Trending tracks={tracks} days={days} blocked={blocked} onOpen={open} />
  return (
    <div class="reader-feed music">
      {!page && (
        <div class="music-top">
          <input type="search" class="music-search" value={query} onInput={e => setQuery(e.currentTarget.value)} placeholder="Search Wavlake"
            aria-label="Search Wavlake" enterkeyhint="search" autocapitalize="off" autocorrect="off" spellcheck={false} />
          {!query.trim() && (
            <div class="reader-scope-row" role="tablist" aria-label="Trending">
              {[...wl.WINDOWS, { days: "following", label: "Following" }].map(w => <button key={w.days} type="button" role="tab" aria-selected={days === w.days} class={days === w.days ? "on" : ""} onClick={() => setDays(w.days)}>{w.label}</button>)}
            </div>
          )}
        </div>
      )}
      {error && <div class="status-line">{error}</div>}
      {body}
      <a class="music-credit muted small" href="https://wavlake.com" target="_blank" rel="noopener noreferrer">Music from Wavlake</a>
      <PlayerBar />
    </div>
  )
}

function Trending({ tracks, days, blocked, onOpen }) {
  if (tracks === null) return <p class="empty">Loading trending songs…</p>
  const shown = wl.visibleTracks(tracks, blocked)
  if (!shown.length) return <p class="empty">{tracks.length ? "Every song here is by someone you blocked." : "No songs found."}</p>
  const span = days === 7 ? "this week" : "this month"
  const artists = wl.topArtists(shown), albums = wl.topAlbums(shown)
  return <>
    <YourArtists blocked={blocked} onOpen={onOpen} />
    {artists.length > 0 && <><h3 class="music-head">Top artists {span}</h3><Row items={artists.map(a => ({ key: a.id, title: a.name, sub: "Artist", art: a.art, round: true, open: () => onOpen({ type: "artist", artist: a }) }))} /></>}
    {albums.length > 0 && <><h3 class="music-head">Top albums {span}</h3><Row items={albums.map(a => ({ key: a.id, title: a.title, sub: a.artist, art: a.art, open: () => onOpen({ type: "album", album: a }) }))} /></>}
    <h3 class="music-head">Trending songs {span}</h3>
    <Tracks tracks={shown} />
  </>
}

const artistTiles = (artists, onOpen) => artists.map(a => ({ key: a.id, title: a.name, sub: "Artist", art: a.art, round: true, open: () => onOpen({ type: "artist", artist: a }) }))

/** Artists you've played or opened, newest first; it follows the player, so a song starting moves its artist up. */
export function YourArtists({ blocked, onOpen }) {
  const [recent, setRecent] = useState(wl.loadRecent)
  useEffect(() => onPlayer(() => setRecent(wl.loadRecent())), [])
  const shown = wl.visibleArtists(recent, blocked)
  if (!shown.length) return null
  return <><h3 class="music-head">Your artists</h3><Row items={artistTiles(shown, onOpen)} /></>
}

/** The Wavlake artists among the people you follow, then their ranked songs. */
export function Following({ follows, loaded, blocked, onOpen }) {
  const [found, setFound] = useState(null)
  const key = follows.length
  useEffect(() => {
    if (!follows.length) return setFound(null)
    let live = true
    setFound(null)
    // Blocks are applied when drawing (FollowingList), so a new block list doesn't refetch.
    wl.followedArtists({ follows: new Set(follows) }).then(f => live && setFound(f))
    return () => { live = false }
  }, [key])
  return <FollowingList follows={follows} loaded={loaded} found={found} blocked={blocked} onOpen={onOpen} />
}

export function FollowingList({ follows, loaded, found, blocked, onOpen }) {
  if (!follows.length) return <p class="empty">{loaded === false ? "Loading your follows…" : "Follow people on Nostr, and the Wavlake artists among them show up here."}</p>
  if (!found) return <p class="empty">Looking for the Wavlake artists you follow…</p>
  const artists = wl.visibleArtists(found.artists, blocked), songs = wl.visibleTracks(found.tracks, blocked)
  if (!artists.length) return <p class="empty">None of the Wavlake artists checked are people you follow. Artists show up here once they link their Nostr key on Wavlake.</p>
  return <>
    <h3 class="music-head">Artists you follow</h3><Row items={artistTiles(artists, onOpen)} />
    {songs.length > 0 && <><h3 class="music-head">Their songs</h3><Tracks tracks={songs} /></>}
  </>
}

function SearchResults({ results, onOpen }) {
  const songs = results.filter(r => r.type === "track").map(r => r.track)
  const more = results.filter(r => r.type !== "track")
  if (!results.length) return <p class="empty">Nothing on Wavlake matches that.</p>
  return <>
    {more.length > 0 && <><h3 class="music-head">Albums and artists</h3><Row items={more.map(r => r.type === "artist"
      ? { key: `ar:${r.artist.id}`, title: r.artist.name, sub: "Artist", art: r.artist.art, round: true, open: () => onOpen({ type: "artist", artist: r.artist }) }
      : { key: `al:${r.album.id}`, title: r.album.title, sub: "Album", art: r.album.art, open: () => onOpen({ type: "album", album: r.album }) })} /></>}
    {songs.length > 0 && <><h3 class="music-head">Songs</h3><Tracks tracks={songs} /></>}
  </>
}

/** Fetch once per id, keeping the last answer for the id shown. */
function usePage(load, id) {
  const [data, setData] = useState(null)
  const [error, setError] = useState("")
  useEffect(() => {
    let live = true
    setData(null); setError("")
    load(id).then(d => live && setData(d)).catch(e => live && setError(`Couldn't reach Wavlake (${e?.message ?? e})`))
    return () => { live = false }
  }, [id])
  return { data, error }
}

function ArtistPage({ id, seed, blocked, onOpen, onBack }) {
  const { data, error } = usePage(async i => { const p = await wl.artist(i); return { ...p, tracks: await wl.tracksOnAlbums(p.albums) } }, id)
  const a = data?.artist ?? seed
  const hidden = data && !wl.visibleArtists([a], blocked).length
  return (
    <div class="music-page">
      <PageBar onBack={onBack} href={wl.artistPage(id)} />
      <div class="music-hero">{a.art ? <img class="round" src={a.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art round" />}<div><h2>{a.name}</h2>{data && <p class="muted small">{data.albums.length === 1 ? "1 album" : `${data.albums.length} albums`} · {wl.songs(data.tracks.length)}</p>}</div></div>
      {error ? <p class="empty">{error}</p> : !data ? <p class="empty">Loading…</p> : hidden ? <p class="empty">You blocked this artist.</p> : <>
        {data.tracks.length > 0 && <div class="music-actions"><button type="button" class="small" onClick={() => playList(wl.visibleTracks(data.tracks, blocked))}>▶ Play all</button></div>}
        {data.albums.length > 0 && <><h3 class="music-head">Albums</h3><Row items={data.albums.map(al => ({ key: al.id, title: al.title, sub: al.year ? String(al.year) : "Album", art: al.art, open: () => onOpen({ type: "album", album: al }) }))} /></>}
        <h3 class="music-head">Songs</h3>
        <Tracks tracks={wl.visibleTracks(data.tracks, blocked)} />
      </>}
    </div>
  )
}

function AlbumPage({ id, seed, blocked, onOpen, onBack }) {
  const { data, error } = usePage(wl.album, id)
  const al = data?.album ?? seed
  const tracks = data ? wl.visibleTracks(data.tracks, blocked) : []
  return (
    <div class="music-page">
      <PageBar onBack={onBack} href={wl.albumPage(id)} />
      <div class="music-hero">{al.art ? <img src={al.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art" />}<div>
        <h2>{al.title}</h2>
        {al.artist && (al.artistId ? <button type="button" class="link" onClick={() => onOpen({ type: "artist", artist: { id: al.artistId, name: al.artist, art: null, npub: null } })}>{al.artist}</button> : <p class="muted">{al.artist}</p>)}
        {data && <p class="muted small">{[al.year, wl.songs(tracks.length)].filter(Boolean).join(" · ")}</p>}
      </div></div>
      {error ? <p class="empty">{error}</p> : !data ? <p class="empty">Loading…</p> : <>
        {tracks.length > 0 && <div class="music-actions"><button type="button" class="small" onClick={() => playList(tracks)}>▶ Play</button></div>}
        {tracks.length ? <Tracks tracks={tracks} numbered /> : <p class="empty">{data.tracks.length ? "Every song here is by someone you blocked." : "No songs on this album."}</p>}
      </>}
    </div>
  )
}

function PageBar({ onBack, href }) {
  return <div class="reader-bar"><button type="button" class="small" onClick={onBack}>‹ Back</button><a class="reader-web small" href={href} target="_blank" rel="noopener noreferrer">Open on Wavlake</a></div>
}

/** A sideways row of covers (artists round). */
function Row({ items }) {
  return <div class="music-row">{items.map(i => (
    <button key={i.key} type="button" class="music-tile" onClick={i.open}>
      {i.art ? <img class={i.round ? "round" : ""} src={i.art} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <div class={`music-art${i.round ? " round" : ""}`} />}
      <span class="music-tile-title">{i.title}</span>{i.sub && <span class="muted small">{i.sub}</span>}
    </button>
  ))}</div>
}

/** Songs; pressing one plays the list from there (or pauses the one playing). */
export function Tracks({ tracks, numbered = false }) {
  const [s, setS] = useState(playerState)
  useEffect(() => onPlayer(setS), [])
  const now = current(s)
  return <ol class="music-tracks">{tracks.map((t, i) => {
    const on = now?.id === t.id
    return (
      <li key={t.id} class={on ? "on" : ""}>
        <button type="button" class="music-track" onClick={() => playList(tracks, i)} aria-label={`${on && s.playing ? "Pause" : "Play"} ${t.title} by ${t.artist}`}>
          {numbered ? <span class="music-num">{on && s.playing ? "▮▮" : i + 1}</span>
            : t.art ? <img src={t.art} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
          <span class="music-track-text"><span class="music-track-title">{t.title}</span><span class="muted small">{t.artist}{t.sats ? ` · ⚡ ${formatSats(t.sats)}` : ""}</span></span>
          <span class="muted small">{on && s.playing ? "Playing" : wl.clock(t.duration)}</span>
        </button>
      </li>
    )
  })}</ol>
}

/** The song playing: cover, title and artist, previous / play-pause / next, time, and its Wavlake page. */
export function PlayerBar() {
  const [s, setS] = useState(playerState)
  useEffect(() => onPlayer(setS), [])
  const t = current(s)
  if (!t) return null
  return (
    <div class="music-player" role="region" aria-label="Now playing">
      {t.art ? <img src={t.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
      <div class="music-track-text"><span class="music-track-title">{t.title}</span><span class="muted small">{s.error || `${t.artist} · ${wl.clock(s.time)}${s.duration ? ` / ${wl.clock(s.duration)}` : ""}`}</span></div>
      <button type="button" class="icon" onClick={previous} aria-label="Previous">⏮</button>
      <button type="button" class="icon" onClick={toggle} aria-label={s.playing ? "Pause" : "Play"}>{s.playing ? "⏸" : "▶"}</button>
      <button type="button" class="icon" onClick={next} aria-label="Next" disabled={s.index + 1 >= s.queue.length}>⏭</button>
      <a class="small" href={wl.trackPage(t.id)} target="_blank" rel="noopener noreferrer" aria-label="Open on Wavlake">↗</a>
    </div>
  )
}
