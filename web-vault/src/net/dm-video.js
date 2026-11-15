// A video in a direct message (Logen 2026-11-15): locked like a photo (dm-file.js, kind 15). Where it was taken comes
// out first (media-privacy.js, as a feed video's upload does), and one that can't fit is refused. The browser has no
// video export to compress with (the feed's web upload sends a video as it is), so it goes as it is; the phone apps
// compress theirs first.
import { MAX_FILE } from "./dm-file.js"
import { withoutLocation } from "./media-privacy.js"

export const TOO_BIG = "That video is too big to send (at most 100 MB). Try a shorter clip."
export const UNREADABLE = "Couldn't read that video."

/** Whether a picked file is a video, by its type. */
export const isVideoFile = f => /^video\//i.test(f?.type ?? "")

/** The file to lock for a picked or dropped video: its bytes without a location, its own type. Throws TOO_BIG (16
 *  bytes of GCM tag are added when it is encrypted), UNREADABLE, or media-privacy's LOCATION_FAILURE. */
export async function prepareVideo(file) {
  if (!isVideoFile(file)) throw new Error(UNREADABLE)
  if (file.size + 16 > MAX_FILE) throw new Error(TOO_BIG)
  let bytes
  try { bytes = new Uint8Array(await file.arrayBuffer()) } catch { throw new Error(UNREADABLE) }
  return new File([withoutLocation(bytes)], file.name || "video.mp4", { type: file.type })
}
