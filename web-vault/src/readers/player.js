// The Music player (the iPhone's MusicPlayerService): one audio element for the page, a queue, play/pause, previous
// and next, and on to the next song when one ends. It lives outside the Music screen, so switching feeds keeps the
// song playing. Wavlake's mediaUrl is a plain MP3. Every song that starts puts its artist in Your artists. Shuffle,
// repeat (off / all / one) and stop work as the iPhone's toggleShuffle, cycleRepeat and stop.
import { rememberRecent, trackArtist } from "./wavlake.js"
const listeners = new Set()
let audio = null
const EMPTY = { queue: [], index: -1, playing: false, time: 0, duration: 0, error: "", shuffled: false, repeat: "off", unshuffled: [] }
let state = { ...EMPTY }
export const REPEATS = ["off", "all", "one"]

const set = patch => { state = { ...state, ...patch }; for (const f of listeners) f(state) }
export const playerState = () => state
export function onPlayer(f) { listeners.add(f); return () => listeners.delete(f) }
export const current = (s = state) => s.queue[s.index] ?? null

/** The page's audio element, made on first use. `make` is for tests. */
export function element(make = () => new Audio()) {
  if (audio) return audio
  audio = make()
  audio.preload = "none"
  audio.addEventListener("play", () => set({ playing: true, error: "" }))
  audio.addEventListener("pause", () => set({ playing: false }))
  audio.addEventListener("timeupdate", () => set({ time: audio.currentTime || 0 }))
  audio.addEventListener("durationchange", () => set({ duration: Number.isFinite(audio.duration) ? audio.duration : 0 }))
  audio.addEventListener("ended", ended)
  audio.addEventListener("error", () => set({ playing: false, error: "This song didn't load." }))
  return audio
}

function load(index) {
  const t = state.queue[index]
  if (!t) return
  const a = element()
  set({ index, time: 0, duration: t.duration ?? 0, error: "" })
  a.src = t.mediaUrl
  nowPlaying(t)
  rememberRecent(trackArtist(t))
  const p = a.play()
  if (p?.catch) p.catch(e => { if (e?.name !== "AbortError") set({ playing: false, error: "Press play to start the song." }) })
}

/** The phone's lock screen and the desktop's media keys (Media Session), as the iPhone's lock-screen controls. */
function nowPlaying(t, ms = globalThis.navigator?.mediaSession) {
  if (!ms || typeof MediaMetadata === "undefined") return
  ms.metadata = new MediaMetadata({ title: t.title, artist: t.artist, album: t.albumTitle ?? "", artwork: t.art ? [{ src: t.art }] : [] })
  for (const [action, f] of [["play", toggle], ["pause", toggle], ["nexttrack", next], ["previoustrack", previous]]) {
    try { ms.setActionHandler(action, f) } catch {}
  }
}

/** Play `tracks` from `at`: the list becomes the queue, so Next walks on through it. Pressing the song already
 *  playing toggles it instead. */
export function playList(tracks, at = 0) {
  const t = tracks[at]
  if (!t) return
  if (current()?.id === t.id) return toggle()
  state = { ...state, queue: tracks.slice(), shuffled: false, unshuffled: [] }
  load(at)
}

/** Fisher–Yates; `random` is for tests. */
export function shuffled(list, random = Math.random) {
  const out = list.slice()
  for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [out[i], out[j]] = [out[j], out[i]] }
  return out
}

/** Plays `tracks` in a random order with shuffle on, so turning it off goes back to the list's own order. */
export function playShuffled(tracks, random) {
  if (!tracks.length) return
  state = { ...state, queue: shuffled(tracks, random), shuffled: true, unshuffled: tracks.slice() }
  load(0)
}

/** Shuffles everything but the song playing, which stays on top and keeps playing; off puts the list's order back
 *  with the current song in its place. */
export function toggleShuffle(random) {
  const t = current()
  if (!t) return
  if (state.shuffled) {
    const back = state.unshuffled.length ? state.unshuffled : state.queue
    set({ queue: back, index: Math.max(0, back.findIndex(x => x.id === t.id)), shuffled: false, unshuffled: [] })
  } else {
    const rest = state.queue.filter((_, i) => i !== state.index)
    set({ unshuffled: state.queue, queue: [t, ...shuffled(rest, random)], index: 0, shuffled: true })
  }
}

/** The songs after this one, with their places in the queue (NowPlayingView's Up Next). */
export const upNext = (s = state) => s.queue.slice(s.index + 1).map((track, i) => ({ track, position: s.index + 1 + i }))

/** Plays the queue's song at `position`, from Up Next. */
export function jump(position) {
  if (position === state.index || !state.queue[position]) return
  load(position)
}

/** Off → repeat all → repeat one → off. */
export const cycleRepeat = () => set({ repeat: REPEATS[(REPEATS.indexOf(state.repeat) + 1) % REPEATS.length] })

/** Is there a song after this one: later in the queue, or round again under repeat all. */
export const hasNext = (s = state) => s.index + 1 < s.queue.length || (s.repeat === "all" && s.queue.length > 0)

/** Stops and clears the queue; the player bar goes away. Repeat stays as chosen, as on the iPhone. */
export function stop() {
  const a = element()
  a.pause()
  a.removeAttribute?.("src")
  set({ ...EMPTY, repeat: state.repeat })
}

function ended() {
  const a = element()
  if (state.repeat === "one") { a.currentTime = 0; const p = a.play(); if (p?.catch) p.catch(() => {}); return }
  next()
}

export function toggle() {
  const a = element()
  if (!current()) return
  if (a.paused) { const p = a.play(); if (p?.catch) p.catch(() => {}) } else a.pause()
}

/** Next song; under repeat all the end of the queue goes round to the first, otherwise it stops there. */
export function next() {
  if (state.index + 1 < state.queue.length) load(state.index + 1)
  else if (hasNext()) load(0)
  else { const a = element(); a.pause(); a.currentTime = 0; set({ playing: false }) }
}

/** Past three seconds, back to the start of this song; otherwise the song before. */
export function previous() {
  const a = element()
  if (a.currentTime > 3 || state.index <= 0) { a.currentTime = 0; return }
  load(state.index - 1)
}

export function seek(seconds) { const a = element(); if (current()) a.currentTime = Math.max(0, seconds) }

/** For tests: forget the element and the queue. */
export function resetPlayer() { audio = null; state = { ...EMPTY }; for (const f of listeners) f(state) }
