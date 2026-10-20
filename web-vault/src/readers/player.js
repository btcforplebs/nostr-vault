// The Music player (the iPhone's MusicPlayerService): one audio element for the page, a queue, play/pause, previous
// and next, and on to the next song when one ends. It lives outside the Music screen, so switching feeds keeps the
// song playing. Wavlake's mediaUrl is a plain MP3.
const listeners = new Set()
let audio = null
let state = { queue: [], index: -1, playing: false, time: 0, duration: 0, error: "" }

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
  audio.addEventListener("ended", () => next())
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
  state = { ...state, queue: tracks.slice() }
  load(at)
}

export function toggle() {
  const a = element()
  if (!current()) return
  if (a.paused) { const p = a.play(); if (p?.catch) p.catch(() => {}) } else a.pause()
}

/** Next song; at the end of the queue it stops. */
export function next() {
  if (state.index + 1 < state.queue.length) load(state.index + 1)
  else { element().pause(); set({ playing: false }) }
}

/** Past three seconds, back to the start of this song; otherwise the song before. */
export function previous() {
  const a = element()
  if (a.currentTime > 3 || state.index <= 0) { a.currentTime = 0; return }
  load(state.index - 1)
}

export function seek(seconds) { const a = element(); if (current()) a.currentTime = Math.max(0, seconds) }

/** For tests: forget the element and the queue. */
export function resetPlayer() { audio = null; state = { queue: [], index: -1, playing: false, time: 0, duration: 0, error: "" }; for (const f of listeners) f(state) }
