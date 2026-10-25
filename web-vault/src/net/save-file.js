// Hands a file the page made (the notes backup .zip) to the user. Call it from a tap: the share sheet needs one.
//
// On a phone or tablet it goes through the share sheet (Save to Files on iOS). An iPhone Home Screen web app ignores
// <a download> for a blob: it opens a viewer and saves nothing, while the page can't tell. A desktop browser gets the
// download, where a share menu would be the odd one out. The download is also the fallback when the share sheet
// won't take the file (Android Chrome refuses big ones with NotAllowedError).

/** -> "shared" | "downloaded" | "cancelled" (the user closed the share sheet: nothing was saved). */
export async function saveFile(blob, name, { nav = globalThis.navigator, doc = globalThis.document } = {}) {
  const file = new File([blob], name, { type: blob.type || "application/octet-stream" })
  if (prefersShare(nav, file)) {
    try {
      await nav.share({ files: [file] })
      return "shared"
    } catch (e) {
      if (e?.name === "AbortError") return "cancelled"
      // Anything else (too large, not allowed): the download below.
    }
  }
  download(blob, name, doc)
  return "downloaded"
}

/** The share sheet on touch devices that can share this file; downloads everywhere else. */
export function prefersShare(nav, file) {
  if (typeof nav?.share !== "function" || typeof nav?.canShare !== "function") return false
  if (!(nav.maxTouchPoints > 0)) return false
  try { return nav.canShare({ files: [file] }) } catch { return false }
}

function download(blob, name, doc) {
  const url = URL.createObjectURL(blob)
  const a = Object.assign(doc.createElement("a"), { href: url, download: name })
  doc.body.append(a); a.click(); a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 60_000)?.unref?.() // unref: Node (tests) doesn't wait a minute for it
}
