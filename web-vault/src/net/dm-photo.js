// A photo in a direct message: one photo per message, cleaned here, then encrypted and uploaded to the account's media
// servers before the message goes out as a kind 15 file message (dm-file.js; a link no server holds would reach them
// dead). A GIF keeps its frames with every metadata block stripped (gif-strip.js); anything else is redrawn as a
// JPEG at most 2400 px on the long edge (LongFormComposeView.coverJPEG), which leaves its EXIF, location included,
// behind: the photo is going to one person, not the camera's record of where it was taken.
import { stripGif } from "./gif-strip.js"
import { decodeImage, drawImage, fitSize as fit } from "./image-compress.js"

export const MAX_EDGE = 2400
/** A picked photo before it's cleaned, as the Messages napplet's limit (dm-dispatch.js MAX_PHOTO). */
export const MAX_PHOTO = 50 * 1024 * 1024
export const JPEG_QUALITY = 0.85

/** A GIF by its own header ("GIF8"), never by its type: a browser takes the type from the file name, so a JPEG
 *  renamed .gif would otherwise go up as it is, EXIF and all. */
export async function isGif(file) {
  const h = new Uint8Array(await file.slice(0, 4).arrayBuffer())
  return h[0] === 0x47 && h[1] === 0x49 && h[2] === 0x46 && h[3] === 0x38
}

/** The drawn size: the long edge brought down to `max`, never up. */
export const fitSize = (width, height, max = MAX_EDGE) => fit(width, height, max)

/**
 * The file to upload for a picked, pasted or dropped photo: a GIF with its metadata blocks stripped, anything else redrawn as a JPEG with no
 * metadata (the browser turns it the right way up from its EXIF first). Throws "Couldn't read that photo." for a file
 * that isn't an image the browser can draw. `draw` is for tests.
 */
export async function preparePhoto(file, { draw = drawJpeg } = {}) {
  if (!file || !(/^image\//.test(file.type) || !file.type)) throw new Error("Couldn't read that photo.")
  if (file.size > MAX_PHOTO) throw new Error("That photo is too big to send (at most 50 MB).")
  if (await isGif(file)) {
    let clean
    try { clean = stripGif(new Uint8Array(await file.arrayBuffer())) } catch { throw new Error("Couldn't read that photo.") }
    return new File([clean], file.name || "photo.gif", { type: "image/gif" })
  }
  let blob
  try { blob = await draw(file) } catch { blob = null }
  if (!blob) throw new Error("Couldn't read that photo.")
  return new File([blob], (file.name || "photo").replace(/\.[^.]*$/, "") + ".jpg", { type: "image/jpeg" })
}

// Drawn by image-compress.js, which every other photo upload uses too.
async function drawJpeg(file) {
  const bmp = await decodeImage(file)
  try { return await drawImage(bmp, { type: "image/jpeg", maxEdge: MAX_EDGE, quality: JPEG_QUALITY }) } finally { bmp.close?.() }
}
