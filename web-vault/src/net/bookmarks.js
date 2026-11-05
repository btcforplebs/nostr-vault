// Bookmarks (NIP-51 kind 10003; parity N1), as the iPhone keeps them (Models/BookmarkList.swift): notes by `e`,
// articles and other addressable events by `a`, public in the tags and private in the encrypted content. A tap
// changes one public entry and keeps every other tag, and the private part, as it is. A note bookmarked only privately
// offers nothing: adding it to the public tags would show it to everyone. Saving reads the list again first and never
// signs over a newer copy (list-edit.js publishList).
import { latestList, publishList } from "./list-edit.js"
import { decrypterFor } from "./blocks.js"

export const BOOKMARKS_KIND = 10003

/** The entry for an event: "a:<kind>:<pubkey>:<d>" for addressable kinds (an edited article stays bookmarked), else
 *  "e:<id>". */
export function entryFor(ev) {
  if (ev.kind >= 30000 && ev.kind < 40000) {
    const d = (ev.tags ?? []).find(t => t.length >= 2 && t[0] === "d")?.[1] ?? ""
    return `a:${ev.kind}:${String(ev.pubkey).toLowerCase()}:${d}`
  }
  return `e:${String(ev.id).toLowerCase()}`
}
/** A tag as an entry, or null for any other tag. */
export const entryOfTag = t => (Array.isArray(t) && t.length >= 2 && t[1] ? (t[0] === "e" ? `e:${t[1].toLowerCase()}` : t[0] === "a" ? `a:${t[1]}` : null) : null)
const tagOf = entry => (entry.startsWith("e:") ? ["e", entry.slice(2)] : ["a", entry.slice(2)])
/** The bookmarks in `tags`, newest first (NIP-51 appends at the end), each once. */
export function entries(tags = []) {
  const seen = new Set()
  return [...tags].reverse().map(entryOfTag).filter(e => e && !seen.has(e) && seen.add(e))
}
export const contains = (tags = [], entry) => tags.some(t => entryOfTag(t) === entry)
/** `tags` with `entry` added at the end (`on`) or every copy taken out; every other tag stays where it was. */
export function toggled(tags = [], entry, on) {
  if (on) return contains(tags, entry) ? tags : [...tags, tagOf(entry)]
  return tags.filter(t => entryOfTag(t) !== entry)
}
/** What a note's menu offers: "add", "remove", or "privately" (bookmarked only in the private part: nothing). */
export function menuState(publicTags, privateSet, entry) {
  if (contains(publicTags, entry)) return "remove"
  return privateSet.has(entry) ? "privately" : "add"
}
/** The private bookmarks: the decrypted content, a JSON array of tags. Empty for anything else. */
export function privateEntries(plaintext) {
  try { const a = JSON.parse(plaintext); return Array.isArray(a) ? entries(a.filter(Array.isArray)) : [] } catch { return [] }
}

// This session's copy: { pubkey, event, privateSet, privateNote }, read once and after each save. Listeners redraw.
let state = { pubkey: null, event: undefined, privateSet: new Set(), privateNote: "" }
let loading = null
const listeners = new Set()
export const onBookmarks = cb => { listeners.add(cb); return () => listeners.delete(cb) }
export const bookmarksState = () => state
const changed = () => { for (const cb of listeners) cb() }

async function opened(ctx, event) {
  if (!event?.content) return { privateSet: new Set(), privateNote: "" }
  const opener = await decrypterFor(ctx.session, { signer: ctx.signer }).catch(() => null)
  if (!opener?.decrypt) return { privateSet: new Set(), privateNote: opener?.reason ?? "no way to decrypt" }
  try { return { privateSet: new Set(privateEntries(await opener.decrypt(event.content))), privateNote: "" } }
  catch (e) { return { privateSet: new Set(), privateNote: String(e?.message ?? e) } }
}

/** Reads the newest list (Haven at once, then the relays) and opens its private part. -> state */
export function loadBookmarks(ctx, { latest = latestList } = {}) {
  const me = ctx.session.pubkey
  if (state.pubkey === me && state.event !== undefined && !loading) return Promise.resolve(state)
  if (loading && state.pubkey === me) return loading
  if (state.pubkey !== me) state = { pubkey: me, event: undefined, privateSet: new Set(), privateNote: "" }
  loading = latest(ctx, BOOKMARKS_KIND).then(async r => {
    const priv = await opened(ctx, r.event)
    if (state.pubkey === me) { state = { pubkey: me, event: r.event ?? null, checked: r.checked, ...priv }; changed() }
    return state
  }).finally(() => { loading = null })
  return loading
}

/** Adds or removes one public bookmark and saves the list. Throws list-edit.js ListNotSaved (and the like) on failure. */
export async function setBookmark(ctx, ev, on, { latest = latestList, publish = publishList } = {}) {
  const fresh = await latest(ctx, BOOKMARKS_KIND)
  const entry = entryFor(ev)
  const tags = toggled(fresh.event?.tags ?? [], entry, on)
  const { event } = await publish(ctx, BOOKMARKS_KIND, tags, { previous: fresh.event ?? undefined, latest: async () => fresh })
  const priv = event.id === state.event?.id ? state : await opened(ctx, event)
  state = { pubkey: ctx.session.pubkey, event, checked: true, privateSet: priv.privateSet, privateNote: priv.privateNote }
  changed()
  return state
}
