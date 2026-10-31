// A live stream's actions (the iPhone's LiveStreamMoreMenu and LiveHostFollowButton since #1306): the ⋯ menu with
// Share as a note, Share, Copy link (nostrvault.app/thread/<naddr>), Share the host's profile and Open in zap.stream;
// and Follow / Following beside the host's name. "Share as a note" opens the note ready to read and post, never
// posted for you.
import { useEffect, useRef, useState } from "preact/hooks"
import { toggleFollow } from "../components/AuthorQuickMenu.jsx"
import { Dialog } from "../components/Moderation.jsx"
import { getProfile } from "../net/profiles.js"
import { publishNote } from "../net/sync.js"
import { shareLink, copyLink } from "./share.js"
import { noteText, profileShareLink, streamNaddr, streamShareLink } from "./live-chat.js"
import { streamLink } from "./live.js"
import { liveQuoteTags } from "../net/live-note.js"

export const hostName = pk => { const p = getProfile(pk); return p?.display_name || p?.name || `${pk.slice(0, 8)}…` }

/** The note "Share as a note" starts from (LiveStreamShare.noteText). */
export const shareNoteText = s => noteText({ hostName: hostName(s.host), naddr: streamNaddr(s) })

export function LiveMoreMenu({ ctx, stream: s }) {
  const [open, setOpen] = useState(false)
  const [note, setNote] = useState(false)
  const [toast, setToast] = useState("")
  const box = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!box.current?.contains(e.target)) setOpen(false) }
    const esc = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [open])
  const say = t => { setToast(t); setTimeout(() => setToast(""), 1800) }
  const pick = f => async () => { setOpen(false); await f() }
  const how = r => ({ copied: "Link copied", shared: "", cancelled: "", failed: "Couldn't copy the link" }[r] ?? "")
  const readOnly = !ctx.signer || ctx.signer.readOnly
  return (
    <span class="live-more" ref={box}>
      <button type="button" class="small" aria-label="More" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(o => !o)}>⋯</button>
      {open && (
        <span class="live-menu" role="menu">
          {!readOnly && <button role="menuitem" onClick={pick(() => setNote(true))}>Share as a note</button>}
          <button role="menuitem" onClick={pick(async () => say(how(await shareLink(streamShareLink(s), s.title || "Live stream"))))}>Share</button>
          <button role="menuitem" onClick={pick(async () => say(how(await copyLink(streamShareLink(s)))))}>Copy link</button>
          <button role="menuitem" onClick={pick(async () => say(how(await shareLink(profileShareLink(s.host), hostName(s.host)))))}>Share {hostName(s.host)}'s profile</button>
          <a role="menuitem" href={streamLink(s)} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)}>Open in zap.stream</a>
        </span>
      )}
      {toast && <span class="live-toast" role="status">{toast}</span>}
      {note && <ShareNoteDialog ctx={ctx} stream={s} onClose={() => setNote(false)} />}
    </span>
  )
}

/** The note, editable, posted only when you press Post. */
export function ShareNoteDialog({ ctx, stream: s, onClose }) {
  const [text, setText] = useState(() => shareNoteText(s))
  const [busy, setBusy] = useState(false), [err, setErr] = useState(""), [done, setDone] = useState(false)
  const post = async () => {
    setBusy(true); setErr("")
    try {
      // The q tag (NIP-18) for each stream the text still quotes, so other apps count it as a quote of the stream.
      const r = await publishNote(ctx.vault, ctx.signer, ctx.session.pubkey, text.trim(), ctx.account.relays.write, [["a", s.address], ...liveQuoteTags(text)])
      if (!r.relays.some(x => x.ok && !x.local)) throw new Error("No relay took it. Try again.")
      setDone(true); setTimeout(onClose, 900)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  return (
    <Dialog label="Share as a note" onClose={onClose}>
      <h3>Share as a note</h3>
      <textarea class="live-note-text" rows={6} value={text} onInput={e => setText(e.currentTarget.value)} />
      {err && <p class="small live-err">{err}</p>}
      <div class="live-dialog-row">
        <button type="button" onClick={onClose}>Cancel</button>
        <button type="button" class="primary" disabled={busy || done || !text.trim()} onClick={post}>{done ? "Posted" : busy ? "Posting…" : "Post"}</button>
      </div>
    </Dialog>
  )
}

/** Follow / Following beside the host's name; not on your own stream, and not read-only. */
export function FollowHost({ ctx, pubkey }) {
  const [busy, setBusy] = useState(false), [err, setErr] = useState("")
  if (!ctx.signer || ctx.signer.readOnly || pubkey === ctx.session?.pubkey) return null
  const following = ctx.account.follows.includes(pubkey)
  const go = async e => {
    e.preventDefault(); e.stopPropagation()
    setBusy(true); setErr("")
    try { await toggleFollow(ctx, pubkey, !following) } catch (x) { setErr(String(x?.message ?? x)) } finally { setBusy(false) }
  }
  return (
    <>
      <button type="button" class={`live-follow${following ? " on" : ""}`} disabled={busy} onClick={go}>{busy ? "…" : following ? "Following" : "Follow"}</button>
      {err && <span class="small live-err" role="status">{err}</span>}
    </>
  )
}
