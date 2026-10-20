// Music: Wavlake parsing as the iPhone parses it, trending rows, blocks, and the player's queue.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode } from "nostr-tools/nip19"
import * as wl from "../src/readers/wavlake.js"
import { element, playList, playerState, current, next, previous, toggle, resetPlayer } from "../src/readers/player.js"

const T = (o = {}) => ({ id: o.id ?? "t1", title: "Song", artist: "Band", artistId: o.artistId ?? "ar1", albumId: o.albumId ?? "al1", albumTitle: "Record",
  albumArtUrl: "https://cdn/a.jpg", mediaUrl: o.mediaUrl ?? "https://cdn/t.mp3", duration: 187, msatTotal: "21000", ...o })

test("a track needs an http(s) MP3; names, sats and keys are read as the iPhone reads them", () => {
  const t = wl.parseTrack(T({ artistNpub: "npub1xyz", duration: 187.9 }))
  assert.equal(t.sats, 21)
  assert.equal(t.duration, 187)
  assert.equal(t.artistNpub, "npub1xyz")
  assert.equal(wl.parseTrack(T({ mediaUrl: "ftp://x/t.mp3" })), null)
  assert.equal(wl.parseTrack(T({ mediaUrl: undefined })), null)
  assert.equal(wl.parseTrack(T({ artistNpub: "abc" })).artistNpub, null)
  assert.equal(wl.parseTrack({ id: "x", name: "Named", mediaUrl: "https://c/t.mp3" }, "Album Artist").artist, "Album Artist")
  assert.equal(wl.parseTrack(T({ albumArtUrl: "javascript:x" })).art, null)
})

test("search rows: tracks to play, albums and artists to open, anything else dropped", () => {
  const r = wl.parseSearch([{ type: "track", ...T() }, { type: "album", id: "al", name: "LP", albumArtUrl: "https://c/a.jpg" }, { type: "artist", id: "ar", name: "Band" }, { type: "podcast", id: "p" }, null])
  assert.deepEqual(r.map(x => x.type), ["track", "album", "artist"])
  assert.equal(r[1].album.title, "LP")
})

test("an artist's albums come newest first, undated last, same-day in Wavlake's order", () => {
  const { artist, albums } = wl.parseArtistPage({ name: "Band", artistNpub: "npub1abc", albums: [
    { id: "old", title: "Old", releaseDate: "2019-01-01" }, { id: "none", title: "Undated" }, { id: "new", title: "New", releaseDate: "2024-05-01" },
    { id: "same1", title: "S1", releaseDate: "2022-02-02" }, { id: "same2", title: "S2", releaseDate: "2022-02-02" }] }, "ar1")
  assert.deepEqual(albums.map(a => a.id), ["new", "same1", "same2", "old", "none"])
  assert.equal(albums[0].year, 2024)
  assert.deepEqual(artist, { id: "ar1", name: "Band", art: null, npub: "npub1abc" })
  assert.equal(wl.parseArtistPage({}, "x").artist, null)
})

test("an album page: heading, tracks in order, the album's artist filling in", () => {
  const p = wl.parseAlbumPage({ id: "al", title: "LP", artist: "Band", releaseDate: "2021-03-03", tracks: [{ id: "1", title: "A", mediaUrl: "https://c/1.mp3" }, { id: "2", title: "B" }] })
  assert.equal(p.album.year, 2021)
  assert.deepEqual(p.tracks.map(t => [t.id, t.artist]), [["1", "Band"]])
})

test("trending rows: each artist and album the first time a song places, capped", () => {
  const tracks = [T({ id: "1", artistId: "x", albumId: "p" }), T({ id: "2", artistId: "y", albumId: "p" }), T({ id: "3", artistId: "x", albumId: "q" })].map(t => wl.parseTrack(t))
  assert.deepEqual(wl.topArtists(tracks).map(a => a.id), ["x", "y"])
  assert.deepEqual(wl.topAlbums(tracks).map(a => a.id), ["p", "q"])
  const many = Array.from({ length: 30 }, (_, i) => wl.parseTrack(T({ id: `t${i}`, artistId: `a${i}` })))
  assert.equal(wl.topArtists(many).length, wl.ROW_LIMIT)
})

test("blocks: by the key a row carries, else by the Wavlake id a page named; albums always stay", () => {
  const hex = "e".repeat(64), npub = npubEncode(hex)
  const blocked = new Set([hex])
  const own = wl.parseTrack(T({ id: "1", artistId: "known", artistNpub: npub }))
  const keyless = wl.parseTrack(T({ id: "2", artistId: "known" }))
  const other = wl.parseTrack(T({ id: "3", artistId: "fine" }))
  assert.deepEqual(wl.visibleTracks([own, keyless, other], blocked, new Set()).map(t => t.id), ["2", "3"], "before any page named the key")
  const ids = wl.blockedArtistIds(blocked, new Map([["known", npub]]))
  assert.deepEqual(wl.visibleTracks([own, keyless, other], blocked, ids).map(t => t.id), ["3"])
  const results = [{ type: "artist", artist: { id: "known" } }, { type: "album", album: { id: "al" } }, { type: "track", track: keyless }]
  assert.deepEqual(wl.visibleResults(results, blocked, ids).map(r => r.type), ["album"])
  assert.equal(wl.visibleTracks([own], new Set(), new Set()).length, 1, "nothing blocked, nothing hidden")
})

test("fetching: the right URLs, an artist page remembers the key it names", async () => {
  const asked = []
  const get = async url => { asked.push(url); return url.includes("/artist/") ? { name: "Band", artistNpub: npubEncode("e".repeat(64)), albums: [{ id: "al1" }] } : url.includes("/album/") ? { id: "al1", tracks: [T()] } : [T()] }
  await wl.trending(30, get)
  await wl.search("lo fi", get)
  const page = await wl.artist("ar 1", get)
  assert.equal((await wl.tracksOnAlbums(page.albums, get)).length, 1)
  assert.deepEqual(asked, [`${wl.API}/rankings?sort=sats&days=30`, `${wl.API}/search?term=lo%20fi`, `${wl.API}/artist/ar%201`, `${wl.API}/album/al1`])
  assert.ok(wl.blockedArtistIds(new Set(["e".repeat(64)])).has("ar 1"))
  const failing = await wl.tracksOnAlbums([{ id: "bad" }, { id: "al1" }], async url => { if (url.endsWith("bad")) throw new Error("x"); return { id: "al1", tracks: [T()] } })
  assert.equal(failing.length, 1, "an album that fails is left out")
})

test("clock and counts", () => {
  assert.equal(wl.clock(187), "3:07")
  assert.equal(wl.clock(null), "")
  assert.equal(wl.songs(1), "1 song")
})

/** A stand-in for the page's <audio>. */
function fakeAudio() {
  const on = {}
  return { paused: true, currentTime: 0, duration: NaN, src: "", addEventListener: (k, f) => { on[k] = f },
    play() { this.paused = false; on.play?.(); return Promise.resolve() }, pause() { this.paused = true; on.pause?.() }, fire: k => on[k]?.() }
}

test("the player: a list becomes the queue, songs run on, previous restarts past 3 s, the same song toggles", () => {
  resetPlayer()
  const a = element(fakeAudio)
  const list = ["1", "2", "3"].map(id => wl.parseTrack(T({ id, mediaUrl: `https://cdn/${id}.mp3` })))
  playList(list, 1)
  assert.equal(current().id, "2")
  assert.equal(a.src, "https://cdn/2.mp3")
  assert.ok(playerState().playing)
  a.fire("ended")
  assert.equal(current().id, "3")
  a.fire("ended")
  assert.equal(current().id, "3", "the end of the queue stops")
  assert.equal(playerState().playing, false)
  a.currentTime = 10
  previous()
  assert.equal(current().id, "3")
  assert.equal(a.currentTime, 0)
  previous()
  assert.equal(current().id, "2")
  playList(list, 1)
  assert.equal(a.paused, true, "pressing the song playing pauses it")
  toggle()
  assert.equal(a.paused, false)
  next()
  assert.equal(current().id, "3")
  resetPlayer()
})
