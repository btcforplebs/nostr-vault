// Bookmarks in the Reader (plan NV_WEB_ONE_PLAN.md step 6a): the Reader draws your bookmarked notes as it draws any
// list; the shell reads the list (net/bookmarks.js, private part opened by your signer here, never in the frame) and
// the notes it names (net/bookmark-notes.js), and hands over the signed events only. Remove Bookmark stays in the
// note's ⋯ menu (the shell's); a change comes to the Reader as inc nv.bookmarks.changed and it asks again.
//   napplet:bookmarks/list {} -> { data: { public: [event|null], private: [event|null], privateNote } }
// The Reader's only.
import { READER_DTAG as READER } from "./first-party-list.js"

export const BOOKMARKS_TOPIC = "nv.bookmarks.changed"

/** The answer from the list's state and the notes found: events whose signature checks, null where none (or a bad one). */
export function bookmarksAnswer(found, privateNote, verify) {
  const ok = ev => { try { return ev && verify(JSON.parse(JSON.stringify(ev))) ? ev : null } catch { return null } }
  return { public: found.public.map(ok), private: found.private.map(ok), privateNote: typeof privateNote === "string" ? privateNote.slice(0, 200) : "" }
}

/** `read()` -> { public: [event|null], private: [event|null], privateNote }; `onChange(cb)` -> off. -> off() */
export function bookmarkIntents({ bus, me, read, verify, onChange }) {
  const off = bus.register({ id: "shell-bookmarks-list", title: "Bookmarks", archetype: "bookmarks", actions: ["list"], conventions: [], deliver: async (_, from) => {
    if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
    const r = await read()
    return { ok: true, data: bookmarksAnswer(r, r.privateNote, verify) }
  } })
  const offChange = onChange(() => bus.emit(me, BOOKMARKS_TOPIC, {}))
  return () => { off(); offChange() }
}
