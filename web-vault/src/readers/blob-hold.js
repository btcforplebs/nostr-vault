// Who still needs a blob: URL. A DM video is decrypted into one (components/DmPhoto.jsx) and its bubble revokes it
// when it unmounts; once the player has it too (player.js playVideo), the sound would stop when the chat closes. Each
// user holds it and lets go; the last one to let go revokes it. URLs that aren't blob: are left alone.
const holds = new Map()
const isBlob = url => typeof url === "string" && url.startsWith("blob:")

/** One more user of `url`. */
export function holdBlob(url) { if (isBlob(url)) holds.set(url, (holds.get(url) ?? 0) + 1) }

/** One user fewer; the last revokes it. `revoke` is for tests. */
export function releaseBlob(url, revoke = u => URL.revokeObjectURL(u)) {
  if (!isBlob(url)) return
  const n = (holds.get(url) ?? 1) - 1
  if (n > 0) { holds.set(url, n); return }
  holds.delete(url)
  revoke(url)
}

/** How many hold `url` (tests). */
export const blobHolds = url => holds.get(url) ?? 0
