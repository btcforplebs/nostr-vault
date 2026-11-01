// The note being written, as one model: its text, the @Name tokens in it, and its photos with their upload state
// (ComposeView's draft on the iPhone, shared rules for all apps, 2026-11-01). A photo picked while there is text goes in
// at the cursor: a "[photo N]" placeholder holds its place while it uploads and becomes its link when the upload is
// done. A photo picked into an empty box, or whose place was deleted, is not placed: its link goes at the end, as before.
// Pure functions, so the composer and the tests share them.

export const EMPTY_DRAFT = Object.freeze({ text: "", mentions: {}, photos: [] })

/** The placeholder for photo `id` while it uploads. */
export const photoToken = id => `[photo ${id}]`

/**
 * `token` (or a link) put in `text` at `caret` on a line of its own. -> { text, caret: just after it }
 * Selected text is replaced, as typing would.
 */
export function insertAtCaret(text, caret, token, end = caret) {
  const at = Math.max(0, Math.min(caret ?? text.length, text.length)), to = Math.max(at, Math.min(end ?? at, text.length))
  // The line break stands in for the space beside it: "word |word" gives "word\n[photo]\nword", not a stray space.
  const before = text.slice(0, at).replace(/ $/, ""), after = text.slice(to).replace(/^ /, "")
  const lead = before && !before.endsWith("\n") ? "\n" : ""
  const tail = !after.startsWith("\n") ? "\n" : ""
  const next = before + lead + token + tail + after
  return { text: next, caret: before.length + lead.length + token.length + tail.length }
}

/** Photos added at `caret`: placeholders in when the box has text, else unplaced. -> the next draft. */
export function addPhotos(draft, added, caret, end) {
  let { text } = draft, at = caret, to = end
  if (text.trim()) {
    for (const p of added) { const r = insertAtCaret(text, at, photoToken(p.id), to); text = r.text; at = to = r.caret }
  }
  return { ...draft, text, photos: [...draft.photos, ...added] }
}

/** Photo `id` changed (`patch`); once it has its link, its placeholder becomes the link. -> the next draft. */
export function updatePhoto(draft, id, patch) {
  const photos = draft.photos.map(p => (p.id === id ? { ...p, ...patch } : p))
  // A function, not a replacement string: a server's URL with $' or $& in it must go in as it is (Tron, #1510).
  const text = patch.url ? draft.text.replace(photoToken(id), () => patch.url) : draft.text
  return { ...draft, text, photos }
}

/** Photo `id` taken off: out of the list, and its placeholder or placed link out of the text. -> the next draft. */
export function removePhoto(draft, id) {
  const p = draft.photos.find(x => x.id === id)
  let { text } = draft
  for (const mark of [photoToken(id), p?.url].filter(Boolean)) {
    const i = text.indexOf(mark)
    if (i < 0) continue
    const nl = text[i + mark.length] === "\n" ? 1 : text[i - 1] === "\n" ? -1 : 0
    text = nl < 0 ? text.slice(0, i - 1) + text.slice(i + mark.length) : text.slice(0, i) + text.slice(i + mark.length + nl)
    break
  }
  return { ...draft, text, photos: draft.photos.filter(x => x.id !== id) }
}

/** Whether a photo's link (or its placeholder) is somewhere in the text. */
export const isPlaced = (text, p) => text.includes(photoToken(p.id)) || (!!p.url && text.includes(p.url))

/**
 * The note's text with its photos: placed ones' placeholders become their links, the placeholders of `drop` (ids of
 * this draft's photos that aren't done: uploading or failed) go, and the links of photos never placed go at the end,
 * one per line, as before. `photos`: the done ones. Only this draft's own placeholders are touched: a "[photo 3]" the
 * user typed stays (Tron, #1510).
 */
export function placeBody(text, photos, drop = []) {
  let body = withoutTokens(text, drop)
  for (const p of photos) if (p.url) body = body.replace(photoToken(p.id), () => p.url)
  body = body.trim()
  const unplaced = photos.filter(p => p.url && !body.includes(p.url)).map(p => p.url)
  return [body, ...unplaced].filter(Boolean).join("\n")
}

/** `text` without the placeholders of photos `ids` (each with the line break it brought), e.g. a draft saved while
 *  they upload: read back later, they'd have nothing behind them. */
export function withoutTokens(text, ids) {
  let t = text
  for (const id of ids) {
    const mark = photoToken(id), i = t.indexOf(mark)
    if (i < 0) continue
    const nl = t[i + mark.length] === "\n" ? 1 : 0
    t = t.slice(0, i) + t.slice(i + mark.length + nl)
  }
  return t.replace(/\n{3,}/g, "\n\n")
}

/** Whether Post has something to send: text, a photo that's up, or one still going up (Post then waits for it). A
 *  failed photo alone is nothing, so it can never send an empty note (Tron, #1510). */
export const hasSomethingToPost = (text, photos) => !!text.trim() || photos.some(p => p.status !== "failed")
