// The notes that use one media file (Logen 2026-11-04, the media viewer's swipe up): every note on the user's own
// vault (Haven's outbox: theirs; its inbox: what others sent them) that names the file by its URL or its sha256 (a
// Blossom name), in the text or any tag (imeta included), whoever wrote it. Nothing is asked of the network. The
// Blossom dialog lists them under the file as "Posted in N notes". Twins: iOS MediaNoteMatch.swift, Android
// MediaNoteMatch.kt.

/** Notes, pictures, videos, file metadata, comments, articles, highlights, polls. */
export const MEDIA_NOTE_KINDS = [1, 20, 21, 22, 1063, 1111, 30023, 9802, 1068, 34235, 34236]
/** Events read from each store at most: the newest, enough for one file's posts. */
export const SCAN_LIMIT = 2000

/** The sha256 a Blossom URL is named by (".../<64 hex>[.ext]"), lowercased, or null. */
export function sha256Of(url) {
  const name = String(url ?? "").split(/[?#]/)[0].split("/").pop().split(".")[0].toLowerCase()
  return /^[0-9a-f]{64}$/.test(name) ? name : null
}

/** Whether `ev` names the file by `url` or `sha256`, in its text or a tag. */
export function usesMedia(ev, url, sha256 = sha256Of(url)) {
  const needles = [String(url ?? "").toLowerCase(), sha256?.length === 64 ? sha256.toLowerCase() : ""].filter(Boolean)
  if (!needles.length) return false
  const hit = s => { const t = String(s ?? "").toLowerCase(); return needles.some(n => t.includes(n)) }
  return hit(ev.content) || (ev.tags ?? []).some(tag => tag.some(hit))
}

/** Every note in `events` that uses the file, newest first, each once. */
export function notesUsing(events, url, sha256 = sha256Of(url)) {
  const seen = new Set()
  return events
    .filter(ev => MEDIA_NOTE_KINDS.includes(ev.kind) && usesMedia(ev, url, sha256) && !seen.has(ev.id) && seen.add(ev.id))
    .sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1))
}

/** The vault's notes that use `blob` ({ url, sha256 }): its outbox and inbox, read locally. */
export async function vaultNotesUsing(vault, blob) {
  const filter = { kinds: MEDIA_NOTE_KINDS, limit: SCAN_LIMIT }
  const [mine, sent] = await Promise.all([
    vault?.outbox?.query(filter).catch(() => []) ?? [],
    vault?.inbox?.query(filter).catch(() => []) ?? [],
  ])
  return notesUsing([...mine, ...sent], blob.url, blob.sha256?.length === 64 ? blob.sha256 : sha256Of(blob.url))
}

/** The text with its links folded away, for a two-line preview. */
export const notePreview = content => String(content ?? "").split(/\s+/).filter(w => w && !/^https?:/i.test(w)).join(" ") || "(media only)"
