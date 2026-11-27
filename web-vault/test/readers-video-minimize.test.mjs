// Video Minimize, as live's (RESEARCH/NV_VIDEO_MINIMIZE_CHECK_2026_11_27.md §3 Web): a note's, Vault or DM video hands
// its sound to the player at the time it was at and pauses in the same step; the clip plays once, seeks, has no
// next/shuffle; a DM's blob: URL lives while anyone holds it; "Back to the video" reopens it at the player's time and
// stops the player.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { element, playList, playVideo, playLive, playerState, current, next, seek, stop, toggleShuffle, cycleRepeat, hasNext, resetPlayer } from "../src/readers/player.js"
import { blobHolds, holdBlob, releaseBlob } from "../src/readers/blob-hold.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { minimizeVideo } = await import("../src/components/MinimizeVideo.jsx")
const { backToVideo, closeReopened, reopened, reopenOf } = await import("../src/readers/VideoReopen.jsx")

function fakeAudio() {
  const on = {}
  return { paused: true, currentTime: 0, duration: NaN, src: "", plays: 0, removeAttribute(k) { if (k === "src") this.src = "" },
    addEventListener: (k, f, o) => { (on[k] ??= []).push({ f, once: o?.once }) },
    play() { this.paused = false; this.plays++; this.fire("play"); return Promise.resolve() }, pause() { this.paused = true; this.fire("pause") },
    fire(k) { const l = on[k] ?? []; on[k] = l.filter(x => !x.once); for (const x of l) x.f() } }
}
const song = id => ({ id, title: id, artist: "A", mediaUrl: `https://c/${id}.mp3`, duration: 100 })
const clip = "https://blossom.example/abc.mp4"
const src = p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")

test("playVideo plays the clip's sound and seeks to its time once the file's length is known", () => {
  resetPlayer(); const a = element(fakeAudio)
  playVideo(clip, 42.5, { author: "pk", title: "" })
  const t = current()
  assert.equal(t.video, true)
  assert.equal(t.title, "Video")
  assert.equal(t.author, "pk")
  assert.equal(a.src, clip)
  assert.equal(a.plays, 1)
  assert.equal(playerState().time, 42.5, "the bar shows where it was at once")
  assert.equal(a.currentTime, 0, "no seek before metadata: it would be lost")
  a.fire("loadedmetadata")
  assert.equal(a.currentTime, 42.5)
  a.currentTime = 50; a.fire("loadedmetadata")
  assert.equal(a.currentTime, 50, "the seek happens once, not on every reload of metadata")
})

test("a clip plays once: ended stops it under any repeat, no next, no shuffle; seek works", () => {
  for (const repeats of [0, 1, 2]) {
    resetPlayer(); const a = element(fakeAudio)
    playVideo(clip, 0)
    for (let i = 0; i < repeats; i++) cycleRepeat()
    assert.equal(hasNext(), false)
    a.fire("ended")
    assert.equal(current(), null, `repeat ${playerState().repeat}: the clip ends and clears`)
  }
  resetPlayer(); const a = element(fakeAudio)
  playVideo(clip, 0)
  next(); assert.equal(current().video, true, "next does nothing for a clip")
  toggleShuffle(); assert.equal(playerState().shuffled, false)
  seek(12); assert.equal(a.currentTime, 12, "a clip seeks, unlike a stream")
})

test("minimizeVideo reads the time at the tap and pauses the viewer in the same step", () => {
  resetPlayer(); element(fakeAudio)
  const v = { currentTime: 17.25, paused: false, pause() { this.paused = true } }
  assert.equal(minimizeVideo(v, clip, { author: "pk" }), true)
  assert.equal(v.paused, true)
  assert.equal(current().mediaUrl, clip)
  assert.equal(current().at, 17.25)
  const end = { currentTime: 9.6, duration: 10, pause() {} }
  minimizeVideo(end, clip)
  assert.equal(current().at, 0, "within a second of the end it starts over, not a moment's sound and gone")
  minimizeVideo({ currentTime: 8.9, duration: 10, pause() {} }, clip)
  assert.equal(current().at, 8.9)
  assert.equal(minimizeVideo(null, clip), false)
  assert.equal(minimizeVideo(v, ""), false)
})

test("a blob: URL is revoked only when its last holder lets go; other URLs are left alone", () => {
  const revoked = []
  const u = "blob:https://x/1"
  holdBlob(u); holdBlob(u)
  releaseBlob(u, x => revoked.push(x)); assert.deepEqual(revoked, [])
  releaseBlob(u, x => revoked.push(x)); assert.deepEqual(revoked, [u])
  holdBlob(clip); assert.equal(blobHolds(clip), 0)
  releaseBlob(clip, x => revoked.push(x)); assert.deepEqual(revoked, [u])
})

test("a DM clip's blob stays alive while the player has it, and goes when the player stops or plays something else", () => {
  const u = "blob:https://x/dm"
  for (const leave of [() => stop(), () => playList([song("1")], 0), () => playLive({ address: "a", streaming: "https://x/l.m3u8" }, "h"), () => playVideo(clip, 0), () => element().fire("ended")]) {
    resetPlayer(); element(fakeAudio)
    holdBlob(u) // the DM bubble
    playVideo(u, 3)
    releaseBlob(u, () => {}) // the chat closes
    assert.equal(blobHolds(u), 1, "the player still holds it")
    leave()
    assert.equal(blobHolds(u), 0, "the player let it go")
  }
})

test("Back to the video reopens the clip at the player's time (not the viewer's old one) and stops the player", () => {
  resetPlayer(); const a = element(fakeAudio)
  const u = "blob:https://x/back"
  holdBlob(u) // the bubble
  playVideo(u, 5, { author: "pk" })
  releaseBlob(u, () => {}) // the chat closed: only the player holds it
  playerState() // the bar played on to 31s
  a.currentTime = 31; a.fire("timeupdate")
  assert.equal(reopenOf().at, 31)
  assert.equal(backToVideo(), true)
  assert.equal(current(), null, "the player let it go: one copy plays")
  assert.equal(a.paused, true)
  assert.deepEqual({ url: reopened().url, at: reopened().at, author: reopened().meta.author }, { url: u, at: 31, author: "pk" })
  assert.equal(blobHolds(u), 1, "the reopened viewer holds the blob across the hand-back")
  closeReopened()
  assert.equal(reopened(), null)
  assert.equal(blobHolds(u), 0)
  playList([song("1")], 0)
  assert.equal(backToVideo(), false, "nothing to reopen for a song")
})

test("every surface has the text Minimize, and the bar and Now Playing have Back to the video", () => {
  assert.match(src("components/MinimizeVideo.jsx"), />Minimize<\/button>/)
  assert.match(src("components/MediaLightbox.jsx"), /<InlineVideo src=\{it\.url\} sound=\{!!it\.sound\} at=\{it\.at \?\? 0\} minimize=\{\{ meta: \{ author, \.\.\.it\.meta \}, onDone: onClose \}\} \/>/)
  assert.match(src("components/NoteMedia.jsx"), /<InlineVideo src=\{item\.url\} minimize=\{\{ meta: \{ author \} \}\} \/>/)
  assert.match(src("components/NoteText.jsx"), /<TextVideo key=\{i\} src=\{s\} author=\{author\}/)
  assert.match(src("screens/BlossomGallery.jsx"), /blob\.kind === "video" && <MinimizeButton video=\{\(\) => ref\.current\?\.querySelector\("\.blossom-view video"\)\} url=\{blob\.url\}/)
  assert.match(src("components/DmPhoto.jsx"), /<MinimizeButton video=\{\(\) => video\.current\} url=\{src\}/)
  assert.match(src("components/DmPhoto.jsx"), /holdBlob\(url\); setSrc\(url\)/)
  assert.doesNotMatch(src("components/DmPhoto.jsx").slice(src("components/DmPhoto.jsx").indexOf("function DmVideo")), /revokeObjectURL/, "the video's blob goes through blob-hold only")
  assert.match(src("readers/PlayerBar.jsx"), /t\.video && <button[^>]*onClick=\{\(\) => backToVideo\(s\)\}>Back to the video<\/button>/)
  assert.match(src("readers/NowPlaying.jsx"), /backToVideo\(s\) \}\}>Back to the video<\/button>/)
  assert.match(src("readers/FloatingPlayer.jsx"), /<ReopenedVideo \/>/)
})

test("Back to the video over an open viewer lets the old viewer's blob go (Tron #2710 point 2)", () => {
  resetPlayer(); element(fakeAudio)
  const a = "blob:https://x/a", b = "blob:https://x/b"
  holdBlob(a); playVideo(a, 1); releaseBlob(a, () => {})
  assert.equal(backToVideo(), true)
  holdBlob(b); playVideo(b, 2); releaseBlob(b, () => {})
  assert.equal(backToVideo(), true)
  assert.equal(blobHolds(a), 0, "the replaced viewer's hold is released")
  assert.equal(blobHolds(b), 1)
  closeReopened()
  assert.equal(blobHolds(b), 0)
})

test("Minimize is drawn only while a player bar is mounted: a guest page has none (Tron #2710 point 1)", async () => {
  const { barMounted, mountBar, onBarMounted } = await import("../src/readers/bar-mounted.js")
  assert.equal(barMounted(), false)
  const seen = []
  const off = onBarMounted(m => seen.push(m))
  const unmount = mountBar()
  assert.equal(barMounted(), true)
  unmount()
  assert.equal(barMounted(), false)
  off()
  assert.deepEqual(seen, [true, false])
  assert.match(src("readers/FloatingPlayer.jsx"), /useEffect\(mountBar, \[\]\)/)
  assert.match(src("components/MinimizeVideo.jsx"), /if \(!bar\) return null/)
  assert.doesNotMatch(src("guest/GuestApp.jsx"), /FloatingPlayer/, "if a guest page gets the bar, Minimize comes back there by itself")
})

test("a minimized feed video scrolled back on screen doesn't start a second copy (Tron #2710 point 3)", () => {
  assert.match(src("components/MediaParts.jsx"), /if \(e\.isIntersecting\) \{ if \(current\(\)\?\.mediaUrl !== src\) v\.play\(\)/)
})
