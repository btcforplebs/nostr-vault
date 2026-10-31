// Settings › Media (iPhone MediaSettingsView, Playback): whether feed videos play by themselves as they scroll into
// view. On by default, as HavenConfig.autoplayVideos. Kept in this browser; read by each video as it mounts.
const AUTOPLAY = "media.autoplayVideos"

export function autoplayOn(storage = globalThis.localStorage) {
  try { return storage?.getItem?.(AUTOPLAY) !== "off" } catch { return true }
}
export function setAutoplay(on, storage = globalThis.localStorage) {
  try { storage?.setItem?.(AUTOPLAY, on ? "on" : "off") } catch {}
}
