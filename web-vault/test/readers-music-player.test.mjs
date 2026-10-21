// The Music player against the iPhone's MusicPlayerService: shuffle keeps the song playing on top and turns back to
// the list's order, repeat cycles off → all → one, repeat all goes round, repeat one replays, stop clears the bar.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { element, playList, playShuffled, playerState, current, next, toggleShuffle, cycleRepeat, hasNext, stop, shuffled, resetPlayer } from "../src/readers/player.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

function fakeAudio() {
  const on = {}
  return { paused: true, currentTime: 0, duration: NaN, src: "", plays: 0, addEventListener: (k, f) => { on[k] = f }, removeAttribute(k) { if (k === "src") this.src = "" },
    play() { this.paused = false; this.plays++; on.play?.(); return Promise.resolve() }, pause() { this.paused = true; on.pause?.() }, fire: k => on[k]?.() }
}
const song = id => ({ id, title: id, artist: "A", artistId: "ar", mediaUrl: `https://c/${id}.mp3`, duration: 100 })
const list = ["1", "2", "3", "4", "5"].map(song)
const ids = () => playerState().queue.map(t => t.id)
const reverse = () => 0 // with Math.floor(0 * (i+1)) = 0 every swap is with the first: a fixed, non-identity order

test("shuffle keeps the song playing on top; off restores the list's order with it in place", () => {
  resetPlayer(); element(fakeAudio)
  playList(list, 2)
  toggleShuffle(reverse)
  assert.equal(current().id, "3")
  assert.equal(playerState().index, 0)
  assert.equal(ids()[0], "3")
  assert.deepEqual([...ids()].sort(), ["1", "2", "3", "4", "5"])
  assert.notDeepEqual(ids(), ["3", "1", "2", "4", "5"], "the rest really is reordered")
  assert.ok(playerState().shuffled)
  next()
  const playing = current().id
  toggleShuffle()
  assert.deepEqual(ids(), ["1", "2", "3", "4", "5"])
  assert.equal(current().id, playing)
  assert.equal(playerState().shuffled, false)
})

test("Shuffle on a page plays in a random order with shuffle on; a new list turns it off", () => {
  resetPlayer(); element(fakeAudio)
  playShuffled(list, reverse)
  assert.ok(playerState().shuffled)
  assert.deepEqual([...ids()].sort(), ["1", "2", "3", "4", "5"])
  toggleShuffle()
  assert.deepEqual(ids(), ["1", "2", "3", "4", "5"])
  playShuffled(list, reverse)
  playList(list, 0)
  assert.equal(playerState().shuffled, false)
})

test("shuffled() is a permutation and leaves its input alone", () => {
  const input = [1, 2, 3, 4, 5, 6]
  const out = shuffled(input)
  assert.deepEqual([...out].sort(), input)
  assert.deepEqual(input, [1, 2, 3, 4, 5, 6])
})

test("repeat: off → all → one → off; all goes round at the end; one replays the song", () => {
  resetPlayer(); const a = element(fakeAudio)
  playList(list, 4)
  assert.equal(playerState().repeat, "off")
  assert.equal(hasNext(), false)
  a.fire("ended")
  assert.equal(current().id, "5", "off: the end stops")
  assert.equal(playerState().playing, false)
  cycleRepeat()
  assert.equal(playerState().repeat, "all")
  assert.equal(hasNext(), true)
  a.fire("ended")
  assert.equal(current().id, "1", "all: round to the first")
  cycleRepeat()
  assert.equal(playerState().repeat, "one")
  const plays = a.plays
  a.currentTime = 99
  a.fire("ended")
  assert.equal(current().id, "1", "one: same song")
  assert.equal(a.currentTime, 0)
  assert.equal(a.plays, plays + 1)
  cycleRepeat()
  assert.equal(playerState().repeat, "off")
})

test("stop clears the queue (the bar goes away) and keeps the repeat choice", () => {
  resetPlayer(); const a = element(fakeAudio)
  playList(list, 1)
  cycleRepeat()
  stop()
  assert.equal(current(), null)
  assert.equal(a.paused, true)
  assert.equal(a.src, "")
  assert.equal(playerState().repeat, "all")
  assert.equal(playerState().queue.length, 0)
  resetPlayer()
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const { PlayButtons, nostrHex } = await import("../src/readers/MusicScreen.jsx")

test("artist and album pages get Play and Shuffle; an artist with a key gets On Nostr", () => {
  const nodes = walk(PlayButtons({ tracks: list, play: "▶ Play all", extra: null }))
  const labels = nodes.filter(n => n.type === "button").map(n => walk(n.props.children).join(""))
  assert.deepEqual(labels, ["▶ Play all", "Shuffle"])
  assert.equal(PlayButtons({ tracks: [], play: "▶ Play" }), null)
  assert.equal(nostrHex("npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"), "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d")
  assert.equal(nostrHex(null), null)
  assert.equal(nostrHex("nsec1xyz"), null)
})

test("Now Playing: seek slider, shuffle, repeat, artist and album open their pages; the bar stops and opens it", () => {
  const src = readFileSync(new URL("../src/readers/NowPlaying.jsx", import.meta.url), "utf8")
  for (const k of ['type="range"', "onInput={e => seek(", "toggleShuffle", "cycleRepeat", 'type: "artist"', 'type: "album"', "disabled={!hasNext(s)}"]) assert.ok(src.includes(k), k)
  const bar = readFileSync(new URL("../src/readers/PlayerBar.jsx", import.meta.url), "utf8")
  assert.match(bar, /onClick=\{stop\}/)
  assert.match(bar, /onClick=\{\(\) => setFull\(true\)\}/)
  const music = readFileSync(new URL("../src/readers/MusicScreen.jsx", import.meta.url), "utf8")
  for (const w of ["Couldn't reach Wavlake. Tap to try again.", "Nothing trending right now.", 'No music found for "{term}".', "Search songs, albums, artists"]) assert.ok(music.includes(w), w)
  assert.match(music, /<PlayerBar onOpen=\{open\} \/>/)
})
