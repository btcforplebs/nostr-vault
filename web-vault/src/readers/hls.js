// Live video in browsers that don't play HLS themselves (Chrome, Firefox, Edge): hls.js feeds the stream to a
// <video> through Media Source Extensions. Safari keeps its own player. hls.js runs without a worker, since the
// vault's CSP (worker-src 'self') blocks the blob worker it would otherwise start, and it is loaded only when a
// stream is opened.

/** How this browser plays an HLS stream: "native" (Safari, iOS), "hlsjs" (Media Source), else "none" (link out). */
export function playMode(video, { mse = globalThis.MediaSource ?? globalThis.ManagedMediaSource } = {}) {
  if (video?.canPlayType?.("application/vnd.apple.mpegurl")) return "native"
  if (typeof mse?.isTypeSupported === "function" && mse.isTypeSupported('video/mp4; codecs="avc1.42E01E,mp4a.40.2"')) return "hlsjs"
  return "none"
}

/** hls.js settings: no worker (CSP), and a live stream starts at the live edge. */
export const HLS_CONFIG = Object.freeze({ enableWorker: false, lowLatencyMode: true, backBufferLength: 30 })

/** Plays `url` in `video` with hls.js. `onFail` runs once on a fatal error hls.js couldn't recover from (the
 *  player then shows the link out). Returns a stop function. `load` is for tests. */
export function attachHls(video, url, onFail, load = () => import("hls.js")) {
  let hls = null, stopped = false, recovered = false
  load().then(({ default: Hls }) => {
    if (stopped) return
    if (!Hls.isSupported()) return onFail?.()
    hls = new Hls(HLS_CONFIG)
    hls.on(Hls.Events.ERROR, (_, data) => {
      if (!data?.fatal) return
      // One retry for a media error (a decode hiccup) as hls.js advises; anything else, or a second one, gives up.
      if (data.type === Hls.ErrorTypes.MEDIA_ERROR && !recovered) { recovered = true; return hls.recoverMediaError() }
      stop()
      onFail?.()
    })
    hls.loadSource(url)
    hls.attachMedia(video)
  }).catch(() => { if (!stopped) onFail?.() })
  const stop = () => { stopped = true; hls?.destroy(); hls = null }
  return stop
}
