// "Bookmark" / "Remove Bookmark" in a note's ••• menu (iPhone BookmarkMenuItem.swift; parity N1): adds or removes the
// note in your public bookmarks (net/bookmarks.js, kind 10003). Bookmarked only privately, it shows "Bookmarked
// privately" and does nothing. Hidden for a read-only sign-in, which can't sign.
import { useEffect, useState } from "preact/hooks"
import { loadBookmarks, bookmarksState, onBookmarks, setBookmark, menuState, entryFor } from "../net/bookmarks.js"

export function BookmarkMenuItem({ ctx, note, onDone }) {
  const [, bump] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  useEffect(() => { loadBookmarks(ctx).catch(() => {}); return onBookmarks(() => bump(n => n + 1)) }, [])
  if (ctx.signer?.readOnly) return null
  const s = bookmarksState()
  const known = s.pubkey === ctx.session.pubkey && s.event !== undefined
  const state = known ? menuState(s.event?.tags ?? [], s.privateSet, entryFor(note)) : null
  if (state === "privately") return <button role="menuitem" disabled title="Change it in the app that made it">🔒 Bookmarked privately</button>
  const go = async () => {
    setBusy(true); setErr("")
    try { await setBookmark(ctx, note, state !== "remove"); onDone?.() }
    catch (e) { setErr(String(e?.message ?? e)) }
    finally { setBusy(false) }
  }
  return (
    <button role="menuitem" disabled={!known || busy} onClick={go} title={err || undefined} aria-busy={busy || undefined}>
      {err ? "Not saved, try again" : busy ? "Saving…" : !known ? "Bookmark…" : state === "remove" ? "Remove Bookmark" : "Bookmark"}
    </button>
  )
}
