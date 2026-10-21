// Full-screen Now Playing and Live minimize, as the iPhone's NowPlayingView / MiniPlayerBar / playLive: a minimized
// stream plays its sound in the player (no seek, next, previous or shuffle), a LIVE badge shows, opening the stream's
// window again takes the sound over, and the stream ending stops it.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { element, playList, playLive, liveAt, liveItem, playerState, current, next, previous, seek, toggleShuffle, hasNext, resetPlayer } from "../src/readers/player.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
function fakeAudio(native = true) {
  const on = {}
  return { paused: true, currentTime: 0, src: "", canPlayType: t => (native && t === "application/vnd.apple.mpegurl" ? "maybe" : ""),
    addEventListener: (k, f) => { on[k] = f }, removeAttribute(k) { if (k === "src") this.src = "" },
    play() { this.paused = false; on.play?.(); return Promise.resolve() }, pause() { this.paused = true; on.pause?.() }, fire: k => on[k]?.() }
}
const stream = { address: "30311:abc:show", title: "NoGood Radio", image: "https://x/p.jpg", streaming: "https://x/live.m3u8", host: "h" }

test("minimize plays the stream's sound in the player as a live item", () => {
  resetPlayer(); const a = element(fakeAudio)
  playLive(stream, "NoGood")
  const t = current()
  assert.equal(t.live, true)
  assert.equal(t.title, "NoGood Radio")
  assert.equal(t.artist, "NoGood")
  assert.equal(a.src, "https://x/live.m3u8", "native HLS plays straight into the audio element")
  assert.ok(liveAt("30311:abc:show"))
  assert.equal(liveAt("30311:abc:other"), null)
  assert.equal(liveItem({ ...stream, title: "" }).title, "Untitled stream")
})

test("a live item has no next, previous, seek or shuffle; the stream ending stops it", () => {
  resetPlayer(); const a = element(fakeAudio)
  playLive(stream, "N")
  assert.equal(hasNext(), false)
  a.currentTime = 50
  previous(); assert.equal(a.currentTime, 50)
  seek(5); assert.equal(a.currentTime, 50)
  next(); assert.equal(a.paused, false, "next doesn't pause a stream")
  toggleShuffle(); assert.equal(playerState().shuffled, false)
  a.fire("ended")
  assert.equal(current(), null)
})

test("a song after a minimized stream replaces it; nothing to play means no minimize", () => {
  resetPlayer(); const a = element(fakeAudio)
  playLive(stream)
  playList([{ id: "s1", title: "Song", artist: "A", mediaUrl: "https://c/1.mp3", duration: 60 }], 0)
  assert.equal(current().live, undefined)
  assert.equal(a.src, "https://c/1.mp3")
  resetPlayer(); element(fakeAudio)
  playLive({ ...stream, streaming: null })
  assert.equal(current(), null)
  resetPlayer()
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (typeof node.type === "function" && !["UpNext"].includes(node.type.name)) walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const { pagesOf } = await import("../src/readers/NowPlaying.jsx")

test("Now Playing's artist and album links open the Music pages", () => {
  const p = pagesOf({ artistId: "ar", artist: "Band", albumId: "al", albumTitle: "LP", art: "a.jpg" })
  assert.deepEqual(p.artist, { type: "artist", artist: { id: "ar", name: "Band", art: null, npub: null } })
  assert.equal(p.album.album.title, "LP")
  assert.deepEqual(pagesOf({ artist: "x" }), { artist: null, album: null })
})

test("wiring: the bar opens Now Playing; Live has Minimize, the bar, and the window takes the sound back", () => {
  const live = readFileSync(new URL("../src/readers/LiveScreen.jsx", import.meta.url), "utf8")
  assert.match(live, /onClick=\{minimize\}[^>]*>Minimize<\/button>/)
  assert.match(live, /<PlayerBar onOpenLive=\{st => setOpen\(st\)\} \/>/)
  assert.match(live, /useEffect\(\(\) => \{ if \(liveAt\(s\.address\)\) stop\(\) \}, \[s\.address\]\)/)
  const np = readFileSync(new URL("../src/readers/NowPlaying.jsx", import.meta.url), "utf8")
  assert.match(np, /Back to the stream/)
  assert.match(np, /if \(e\.key === "Escape"\) onClose\(\)/)
})
