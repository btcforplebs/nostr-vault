// A small copy published with each photo or video a note carries, so Media grids don't read the original
// (media perf review 2026-11-28, finding 1: 48 photos / 28.9 MB for one screen of ~130 px tiles). The grids already
// draw an imeta `thumb` for a photo and a `thumb` or `image` for a video (components/grid-thumb.js, #2717); this makes
// them, on upload:
//
// - a photo -> `thumb`: drawn down to THUMB_EDGE px on its long side, a JPEG (any reader can decode one).
// - a video -> `image`: one frame, a second in (or a tenth of a short clip), drawn down to POSTER_EDGE px. Only where
//   the browser can play the file; a format it can't (or one that never answers within FRAME_WAIT_MS) goes without.
//
// Nothing here ever throws or blocks the upload: no copy -> null, and the file goes up and is posted as before.

import { decodeImage, drawImage } from "./image-compress.js"

/** Long side of a photo's thumb: a grid tile is ~130 CSS px, so 320 is sharp on a 2x-3x screen (blossom-thumbs.js). */
export const THUMB_EDGE = 320
/** Long side of a video's poster: a tile, and the still a player shows before it plays. */
export const POSTER_EDGE = 640
export const PREVIEW_QUALITY = 0.8
/** How long a video gets to give a frame before it goes up without one. */
export const FRAME_WAIT_MS = 5000

const isVideo = f => /^video\//.test(f?.type ?? "")
const isPhoto = f => /^image\//.test(f?.type ?? "") && !/^image\/(gif|svg)/.test(f.type) // a GIF moves; its own first frame is its tile

const named = (file, suffix) => (file.name || "media").replace(/\.[^.]*$/, "") + suffix + ".jpg"

/**
 * The small copy for `file`: { field: "thumb" | "image", file: File (JPEG) }, or null when there's none to make.
 * `decode` / `draw` / `frame` are for tests (frame(file) -> a drawable { width, height, close? } or throws).
 */
export async function previewOf(file, { decode = decodeImage, draw = drawImage, frame = videoFrame } = {}) {
  try {
    if (isPhoto(file)) {
      const bmp = await decode(file)
      try {
        // Already this small: the photo is its own thumb, and a second copy would cost a request for nothing.
        if (!(Math.max(bmp.width, bmp.height) > THUMB_EDGE)) return null
        const blob = await draw(bmp, { type: "image/jpeg", maxEdge: THUMB_EDGE, quality: PREVIEW_QUALITY })
        return blob?.size ? { field: "thumb", file: new File([blob], named(file, "-thumb"), { type: "image/jpeg" }) } : null
      } finally { bmp.close?.() }
    }
    if (isVideo(file)) {
      const still = await frame(file)
      try {
        const blob = await draw(still, { type: "image/jpeg", maxEdge: POSTER_EDGE, quality: PREVIEW_QUALITY })
        return blob?.size ? { field: "image", file: new File([blob], named(file, "-poster"), { type: "image/jpeg" }) } : null
      } finally { still.close?.() }
    }
  } catch {}
  return null
}

/** One frame of a video file as an ImageBitmap (or a canvas where there's no createImageBitmap); throws when the
 *  browser can't play the file or it doesn't answer within FRAME_WAIT_MS. */
export function videoFrame(file, { wait = FRAME_WAIT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const v = document.createElement("video"), url = URL.createObjectURL(file)
    let done = false
    const end = (err, val) => {
      if (done) return
      done = true
      clearTimeout(timer)
      v.removeAttribute("src"); v.load?.()
      URL.revokeObjectURL(url)
      err ? reject(err) : resolve(val)
    }
    const timer = setTimeout(() => end(new Error("no frame in time")), wait)
    v.muted = true; v.playsInline = true; v.preload = "auto"
    v.onerror = () => end(new Error("can't play this video"))
    v.onloadeddata = () => {
      const d = Number.isFinite(v.duration) ? v.duration : 0
      const at = Math.min(1, d / 10)
      if (at > 0.01) v.currentTime = at
      else v.onseeked()
    }
    v.onseeked = async () => {
      try {
        if (!(v.videoWidth > 0 && v.videoHeight > 0)) throw new Error("no picture")
        end(null, typeof createImageBitmap === "function" ? await createImageBitmap(v) : copyToCanvas(v))
      } catch (e) { end(e) }
    }
    v.src = url
  })
}

function copyToCanvas(v) {
  const c = Object.assign(document.createElement("canvas"), { width: v.videoWidth, height: v.videoHeight })
  c.getContext("2d").drawImage(v, 0, 0)
  return c
}
