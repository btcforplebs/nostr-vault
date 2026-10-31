// Music from Wavlake's public catalogue API (the iPhone's WavlakeAPI and WavlakeBlockFilter, Models/Wavlake.swift).
// Wavlake answers with `Access-Control-Allow-Origin: *`, so the page asks it directly. Nothing is stored in Haven.
import { decode } from "nostr-tools/nip19"

export const API = "https://wavlake.com/api/v1/content"
/** Trending is ranked by song; its artist and album rows come out in the order their best song places. */
export const ROW_LIMIT = 15
export const WINDOWS = [{ days: 7, label: "This week" }, { days: 30, label: "This month" }]

const str = v => (typeof v === "string" ? v : null)
const http = s => { try { const u = new URL(s); return /^https?:$/.test(u.protocol) ? u.href : null } catch { return null } }
const npubOf = v => (typeof v === "string" && v.startsWith("npub1") ? v : null)

export const rankingsUrl = (days = 7) => `${API}/rankings?sort=sats&days=${days}`
export const searchUrl = term => `${API}/search?term=${encodeURIComponent(term)}`
export const albumUrl = id => `${API}/album/${encodeURIComponent(id)}`
export const artistUrl = id => `${API}/artist/${encodeURIComponent(id)}`
export const trackPage = id => `https://wavlake.com/track/${encodeURIComponent(id)}`
export const albumPage = id => `https://wavlake.com/album/${encodeURIComponent(id)}`
export const artistPage = id => `https://wavlake.com/artist/${encodeURIComponent(id)}`

/** A track from any payload; rows without an http(s) MP3 link are dropped, there is nothing to play. */
export function parseTrack(j, artistFallback = null) {
  if (!j || typeof j.id !== "string") return null
  const mediaUrl = http(j.mediaUrl)
  if (!mediaUrl) return null
  const msat = Number(j.msatTotal)
  return {
    id: j.id, title: str(j.title) ?? str(j.name) ?? "Untitled", artist: str(j.artist) ?? artistFallback ?? "Unknown artist",
    artistId: str(j.artistId), albumId: str(j.albumId), albumTitle: str(j.albumTitle), art: http(j.albumArtUrl),
    artistArt: http(j.artistArtUrl), mediaUrl, duration: Number.isFinite(Number(j.duration)) && j.duration != null ? Math.floor(Number(j.duration)) : null,
    sats: Number.isFinite(msat) && j.msatTotal != null ? Math.floor(msat / 1000) : null, artistNpub: npubOf(j.artistNpub),
  }
}

export const parseRankings = rows => (Array.isArray(rows) ? rows.map(r => parseTrack(r)).filter(Boolean) : [])

/** Search rows: a track (playable now), or an album or artist to open. */
export function parseSearch(rows) {
  if (!Array.isArray(rows)) return []
  return rows.map(r => {
    if (!r || typeof r.id !== "string") return null
    const name = str(r.name) ?? str(r.title) ?? ""
    if (r.type === "track") { const t = parseTrack(r); return t && { type: "track", track: t } }
    if (r.type === "album") return { type: "album", album: { id: r.id, title: name || "Album", art: http(r.albumArtUrl), artist: null, artistId: null, year: null } }
    if (r.type === "artist") return { type: "artist", artist: { id: r.id, name, art: http(r.artistArtUrl), npub: null } }
    return null
  }).filter(Boolean)
}

export function parseAlbum(j, artistFallback = null) {
  if (!j || typeof j.id !== "string") return null
  return { id: j.id, title: str(j.title) ?? str(j.name) ?? "Untitled", art: http(j.albumArtUrl), artist: str(j.artist) ?? artistFallback,
    artistId: str(j.artistId), year: /^\d{4}/.test(j.releaseDate ?? "") ? Number(j.releaseDate.slice(0, 4)) : null }
}

/** An album page: its heading and tracks in album order (some tracks carry no artist; the album's fills in). */
export function parseAlbumPage(j) {
  return { album: parseAlbum(j), tracks: Array.isArray(j?.tracks) ? j.tracks.map(t => parseTrack(t, str(j.artist))).filter(Boolean) : [] }
}

/** An artist page: name, picture and Nostr key, and albums newest release first (Wavlake lists oldest first; undated
 *  albums go last, same-day ones keep their order). */
export function parseArtistPage(j, id) {
  const name = str(j?.name) ?? str(j?.title) ?? ""
  const artist = name ? { id, name, art: http(j.artistArtUrl), npub: npubOf(j.artistNpub) } : null
  const rows = Array.isArray(j?.albums) ? j.albums : []
  const albums = rows.map((r, i) => ({ a: parseAlbum(r, name || null), d: str(r?.releaseDate) ?? "", i })).filter(x => x.a)
    .sort((x, y) => (x.d !== y.d ? (x.d < y.d ? 1 : -1) : x.i - y.i)).map(x => x.a)
  return { artist, albums }
}

/** Trending's artist and album rows: the first time each appears in the ranked songs, at most ROW_LIMIT. */
export function topArtists(tracks, limit = ROW_LIMIT) {
  const seen = new Set(), out = []
  for (const t of tracks) if (t.artistId && !seen.has(t.artistId)) { seen.add(t.artistId); out.push({ id: t.artistId, name: t.artist, art: t.artistArt, npub: t.artistNpub }) }
  return out.slice(0, limit)
}
export function topAlbums(tracks, limit = ROW_LIMIT) {
  const seen = new Set(), out = []
  for (const t of tracks) if (t.albumId && !seen.has(t.albumId)) { seen.add(t.albumId); out.push({ id: t.albumId, title: t.albumTitle ?? "Album", art: t.art, artist: t.artist, artistId: t.artistId, year: null }) }
  return out.slice(0, limit)
}

// --- Blocks (WavlakeBlockFilter). Wavlake only names an artist's Nostr key on their own page, so a blocked artist is
// recognised by the key when a row carries one, else by their Wavlake id once any page seen this session named that key.

const hexOf = npub => { try { const d = decode(npub); return d.type === "npub" ? d.data : null } catch { return null } }
const knownArtists = new Map() // Wavlake artist id -> npub, from every page that named one
export function rememberArtist(a) { if (a?.id && a.npub) knownArtists.set(a.id, a.npub) }

/** The Wavlake ids of known artists whose key is blocked. */
export function blockedArtistIds(blocked, known = knownArtists) {
  const ids = new Set()
  if (!blocked.size) return ids
  for (const [id, npub] of known) if (blocked.has(hexOf(npub))) ids.add(id)
  return ids
}
const isBlocked = (npub, artistId, blocked, ids) => (npub && blocked.has(hexOf(npub))) || (artistId && ids.has(artistId))
export const visibleTracks = (tracks, blocked, ids = blockedArtistIds(blocked)) => (blocked.size || ids.size ? tracks.filter(t => !isBlocked(t.artistNpub, t.artistId, blocked, ids)) : tracks)
export const visibleArtists = (artists, blocked, ids = blockedArtistIds(blocked)) => (blocked.size || ids.size ? artists.filter(a => !isBlocked(a.npub, a.id, blocked, ids)) : artists)
/** Search carries no keys, so an artist row only drops once a page named their key; albums always stay. */
export function visibleResults(results, blocked, ids = blockedArtistIds(blocked)) {
  if (!blocked.size && !ids.size) return results
  return results.filter(r => r.type === "track" ? !isBlocked(r.track.artistNpub, r.track.artistId, blocked, ids) : r.type === "artist" ? !ids.has(r.artist.id) : true)
}

// --- Fetching. `get` is for tests.

const getJson = async url => {
  const r = await fetch(url, { signal: AbortSignal.timeout?.(15000) })
  if (!r.ok) throw new Error(`Wavlake answered ${r.status}`)
  return r.json()
}
export const trending = (days = 7, get = getJson) => get(rankingsUrl(days)).then(parseRankings)
export const search = (term, get = getJson) => get(searchUrl(term)).then(parseSearch)
export const album = (id, get = getJson) => get(albumUrl(id)).then(parseAlbumPage)
export async function artist(id, get = getJson) {
  const page = parseArtistPage(await get(artistUrl(id)), id)
  rememberArtist(page.artist)
  return page
}
/** The artist's Nostr key (hex) for a song, or null (MusicArtistKey.hex): the npub the song carries, else one a page
 *  named this session, else the artist's own page, the only one Wavlake names it on. One lookup per artist. */
const artistKeys = new Map() // Wavlake artist id -> Promise<hex | null>
export function artistKey(t, get = getJson) {
  if (t?.artistNpub) return Promise.resolve(hexOf(t.artistNpub))
  if (!t?.artistId) return Promise.resolve(null)
  if (knownArtists.has(t.artistId)) return Promise.resolve(hexOf(knownArtists.get(t.artistId)))
  if (!artistKeys.has(t.artistId)) {
    const p = artist(t.artistId, get).then(page => (page.artist?.npub ? hexOf(page.artist.npub) : null)).catch(() => null)
    artistKeys.set(t.artistId, p)
    p.then(hex => { if (!hex) artistKeys.delete(t.artistId) }) // try again on the next song by them
  }
  return artistKeys.get(t.artistId)
}

/** Every track on these albums, album by album in order; an album that fails is left out. */
export async function tracksOnAlbums(albums, get = getJson) {
  const pages = await Promise.all(albums.map(a => album(a.id, get).catch(() => ({ tracks: [] }))))
  return pages.flatMap(p => p.tracks)
}

// --- Your artists and the artists you follow (the iPhone's MusicFeedState recentArtists and followedArtists).

const RECENT_KEY = "nv-music-recent-artists"
export const MAX_RECENT = 20

/** Artists you've played or opened, newest first, saved in this browser. */
export function loadRecent(storage = globalThis.localStorage) {
  try {
    const list = JSON.parse(storage?.getItem(RECENT_KEY) ?? "[]")
    return Array.isArray(list) ? list.filter(a => a && typeof a.id === "string" && typeof a.name === "string") : []
  } catch { return [] }
}

/** Puts `a` first in Your artists, keeping a picture or key an earlier entry had. -> the new list */
export function rememberRecent(a, storage = globalThis.localStorage) {
  if (!a?.id || !a.name) return loadRecent(storage)
  const list = loadRecent(storage)
  const known = list.find(x => x.id === a.id)
  const entry = { id: a.id, name: a.name, art: a.art ?? known?.art ?? null, npub: a.npub ?? known?.npub ?? null }
  const out = [entry, ...list.filter(x => x.id !== a.id)].slice(0, MAX_RECENT)
  try { storage?.setItem(RECENT_KEY, JSON.stringify(out)) } catch {}
  rememberArtist(entry)
  return out
}
export const clearRecent = (storage = globalThis.localStorage) => storage?.removeItem(RECENT_KEY)

/** The artist a song is by, for Your artists. */
export const trackArtist = t => (t?.artistId ? { id: t.artistId, name: t.artist, art: t.artistArt, npub: t.artistNpub } : null)

// Artist pages fetched this session, for their Nostr keys. One with no key is kept too, so it isn't asked twice; a
// failed fetch isn't, so it is asked again next time.
const artistInfo = new Map()

async function mapLimit(items, n, f) {
  const out = new Array(items.length)
  let at = 0
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (at < items.length) { const i = at++; out[i] = await f(items[i]) }
  }))
  return out
}

/** Wavlake artists whose linked Nostr key you follow, and their ranked songs. Wavlake can't be asked which artists a
 *  key follows, and only an artist's own page carries their key, so this checks the artists of the last 90 days'
 *  rankings plus Your artists, as the iPhone does. `follows` and `blocked` are Sets of hex keys.
 *  -> { artists, tracks } */
export async function followedArtists({ follows, blocked = new Set(), recent = loadRecent(), get = getJson, cache = artistInfo }) {
  const ranked = await trending(90, get).catch(() => [])
  const ids = [...new Set([...recent.map(a => a.id), ...ranked.map(t => t.artistId).filter(Boolean)])]
  await mapLimit(ids.filter(id => !cache.has(id)), 8, async id => {
    try { cache.set(id, (await artist(id, get)).artist) } catch {}
  })
  const artists = ids.map(id => cache.get(id)).filter(a => {
    const key = a?.npub && hexOf(a.npub)
    return key && follows.has(key) && !blocked.has(key)
  })
  const followed = new Set(artists.map(a => a.id))
  return { artists, tracks: ranked.filter(t => t.artistId && followed.has(t.artistId)) }
}

/** 3:07 */
export const clock = s => (s == null || !Number.isFinite(s) ? "" : `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`)
export const songs = n => (n === 1 ? "1 song" : `${n} songs`)
