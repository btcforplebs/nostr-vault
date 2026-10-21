// Music: Your artists (played or opened, saved in this browser) and Following (the Wavlake artists among the people
// you follow), as the iPhone's MusicFeedState recentArtists / followedArtists.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { npubEncode } from "nostr-tools/nip19"
import * as wl from "../src/readers/wavlake.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const hex = c => c.repeat(64)
const A = hex("a"), B = hex("b"), C = hex("c")

test("Your artists: newest first, no repeats, capped, keeping a picture or key it had", () => {
  const s = store()
  wl.rememberRecent({ id: "x", name: "X", art: "https://c/x.jpg", npub: "npub1x" }, s)
  wl.rememberRecent({ id: "y", name: "Y" }, s)
  const list = wl.rememberRecent({ id: "x", name: "X", art: null, npub: null }, s)
  assert.deepEqual(list.map(a => a.id), ["x", "y"])
  assert.equal(list[0].art, "https://c/x.jpg")
  assert.equal(list[0].npub, "npub1x")
  for (let i = 0; i < 30; i++) wl.rememberRecent({ id: `a${i}`, name: `A${i}` }, s)
  assert.equal(wl.loadRecent(s).length, wl.MAX_RECENT)
  assert.equal(wl.loadRecent(s)[0].id, "a29")
})

test("Your artists ignores a song with no artist id, and junk in storage", () => {
  const s = store()
  assert.deepEqual(wl.rememberRecent(wl.trackArtist({ artist: "Nobody" }), s), [])
  s.setItem("nv-music-recent-artists", "{not json")
  assert.deepEqual(wl.loadRecent(s), [])
  s.setItem("nv-music-recent-artists", JSON.stringify([{ id: 1 }, { id: "ok", name: "Ok" }, null]))
  assert.deepEqual(wl.loadRecent(s).map(a => a.id), ["ok"])
})

/** A fake Wavlake: 90-day rankings, and artist pages with or without a key; counts requests. */
function fakeWavlake({ rankings, artists, fail = new Set() }) {
  const calls = []
  const get = async url => {
    calls.push(url)
    if (url.includes("/rankings")) { assert.match(url, /days=90/); return rankings }
    const id = decodeURIComponent(url.split("/artist/")[1])
    if (fail.has(id)) throw new Error("503")
    return artists[id] ?? {}
  }
  return { get, calls }
}
const song = (id, artistId) => ({ id, title: id, artist: artistId, artistId, mediaUrl: `https://c/${id}.mp3` })

test("Following: the ranked and recent artists whose key you follow, and their ranked songs", async () => {
  const w = fakeWavlake({
    rankings: [song("s1", "ar-a"), song("s2", "ar-b"), song("s3", "ar-a"), song("s4", "ar-nokey")],
    artists: { "ar-a": { name: "Ann", artistNpub: npubEncode(A) }, "ar-b": { name: "Bob", artistNpub: npubEncode(B) },
      "ar-nokey": { name: "Anon" }, "ar-recent": { name: "Cat", artistNpub: npubEncode(C) } },
  })
  const f = await wl.followedArtists({ follows: new Set([A, C]), recent: [{ id: "ar-recent", name: "Cat" }], get: w.get, cache: new Map() })
  assert.deepEqual(f.artists.map(a => a.name), ["Cat", "Ann"], "recent first, then ranked order; Bob isn't followed")
  assert.deepEqual(f.tracks.map(t => t.id), ["s1", "s3"])
})

test("Following leaves out blocked artists, asks each artist once, and asks a failed one again", async () => {
  const cache = new Map()
  const w = fakeWavlake({ rankings: [song("s1", "ar-a"), song("s2", "ar-b")], artists: { "ar-a": { name: "Ann", artistNpub: npubEncode(A) }, "ar-b": { name: "Bob", artistNpub: npubEncode(B) } }, fail: new Set(["ar-b"]) })
  const f = await wl.followedArtists({ follows: new Set([A, B]), blocked: new Set([A]), recent: [], get: w.get, cache })
  assert.deepEqual(f.artists, [])
  assert.equal(cache.has("ar-a"), true)
  assert.equal(cache.has("ar-b"), false, "a failed page isn't cached")
  const w2 = fakeWavlake({ rankings: [song("s1", "ar-a"), song("s2", "ar-b")], artists: { "ar-b": { name: "Bob", artistNpub: npubEncode(B) } } })
  const g = await wl.followedArtists({ follows: new Set([A, B]), recent: [], get: w2.get, cache })
  assert.deepEqual(w2.calls.filter(u => u.includes("/artist/")).map(u => u.split("/artist/")[1]), ["ar-b"])
  assert.deepEqual(g.artists.map(a => a.name), ["Ann", "Bob"])
})

test("Following with Wavlake down: Your artists still checked, nothing ranked", async () => {
  const get = async url => { if (url.includes("/rankings")) throw new Error("down"); return { name: "Cat", artistNpub: npubEncode(C) } }
  const f = await wl.followedArtists({ follows: new Set([C]), recent: [{ id: "ar-c", name: "Cat" }], get, cache: new Map() })
  assert.deepEqual(f.artists.map(a => a.id), ["ar-c"])
  assert.deepEqual(f.tracks, [])
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(n => walk(n, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (node.type?.name === "Tracks") return out // uses hooks; no songs in these cases anyway
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const text = n => walk(n).filter(x => typeof x === "string").join(" ")
const { FollowingList } = await import("../src/readers/MusicScreen.jsx")

test("Following screen: the iPhone's messages, and blocks applied when drawn", () => {
  assert.match(text(FollowingList({ follows: [], loaded: true, found: null, blocked: new Set() })), /Follow people on Nostr/)
  assert.match(text(FollowingList({ follows: [A], found: null, blocked: new Set() })), /Looking for/)
  assert.match(text(FollowingList({ follows: [A], found: { artists: [], tracks: [] }, blocked: new Set() })), /None of the Wavlake artists checked/)
  const found = { artists: [{ id: "ar-a", name: "Ann", npub: npubEncode(A) }, { id: "ar-b", name: "Bob", npub: npubEncode(B) }], tracks: [] }
  const t = text(FollowingList({ follows: [A, B], found, blocked: new Set([B]) }))
  assert.match(t, /Artists you follow/)
  assert.match(t, /Ann/)
  assert.equal(t.includes("Bob"), false)
})

test("the player puts each song's artist in Your artists; opening an artist page does too", () => {
  assert.match(readFileSync(new URL("../src/readers/player.js", import.meta.url), "utf8"), /nowPlaying\(t\)\n\s*if \(!t\.live\) rememberRecent\(trackArtist\(t\)\)/)
  assert.match(readFileSync(new URL("../src/readers/MusicScreen.jsx", import.meta.url), "utf8"), /if \(p\.type === "artist"\) wl\.rememberRecent\(p\.artist\)/)
})
