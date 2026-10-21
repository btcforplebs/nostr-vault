// One conversation (iPhone DMThreadView): their messages on the left, the user's on the right, a field and Send at
// the bottom. Sending is NIP-17 through net/dms.js; the sent text shows at once and stays in memory only. A photo
// (picked, pasted or dropped, one per message) is uploaded first and its link sent after the text (net/dm-photo.js).
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { dmPrefill, hasLegacy, sendMessage, sendFailure, thread } from "../net/dms.js"
import { dmContent, preparePhoto } from "../net/dm-photo.js"
import { markRead } from "../net/dm-read.js"
import { mediaServers, uploadPhoto } from "../net/upload.js"
import { useMessages, SignerTrouble, AuthTrouble, OpenMore } from "./MessagesScreen.jsx"

/** Return sends, as on the Mac app and every desktop chat; Shift or Option + Return is a new line. On a touch screen
 *  Return is a new line and Send is the button, as on the iPhone. Never mid-composition (an IME's Return picks a word). */
export const sendsOnEnter = (e, touch) => e.key === "Enter" && !e.shiftKey && !e.altKey && !e.isComposing && e.keyCode !== 229 && !touch
const coarse = () => globalThis.matchMedia?.("(pointer: coarse)").matches ?? false
const fiveLines = el => { const cs = getComputedStyle(el); return parseFloat(cs.lineHeight || "20") * 5 + parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom) + 2 }

// A pasted image can come without a type; preparePhoto decides whether it's a drawable image.
const isImageFile = f => !f.type || /^image\//.test(f.type)

export function ConversationScreen({ ctx, peer }) {
  const { messages, note, trouble, retry, refresh, more, loaded } = useMessages(ctx)
  const { blocked } = useBlocks(ctx)
  // A link may start the box with a message (DMThreadView initialMessage): typed in, never sent until Send.
  const [text, setText] = useState(() => dmPrefill().text)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [photo, setPhoto] = useState(null) // { file, preview } ready to upload with the next send
  const [preparing, setPreparing] = useState(false) // a photo being redrawn: Send waits for it
  const [dragging, setDragging] = useState(false)
  const end = useRef(null)
  const picker = useRef(null)
  const field = useRef(null)
  // Grows with the text up to five lines, then scrolls (DMThreadView lineLimit(1...5)); back to one line once sent.
  useEffect(() => { const el = field.current; if (el) { el.style.height = "auto"; el.style.height = `${Math.min(el.scrollHeight, fiveLines(el))}px` } }, [text])
  const me = ctx.session.pubkey
  const rows = thread(messages, peer)
  const isBlocked = blocked.has(peer)
  const follows = ctx.account.follows.includes(peer)

  useEffect(() => { const { text: t, hash } = dmPrefill(); if (t) history.replaceState(history.state, "", hash) }, [])
  useEffect(() => { fetchProfiles(ctx.vault, [peer], uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {}) }, [peer])
  useEffect(() => { end.current?.scrollIntoView?.({ block: "end" }) }, [rows.length])
  // What's on screen is read: on opening, and as messages land while the tab is in front (DMThreadView markAsRead).
  useEffect(() => {
    const read = () => { if (document.visibilityState !== "hidden" && !isBlocked) markRead(me, rows) }
    read()
    document.addEventListener("visibilitychange", read)
    return () => document.removeEventListener("visibilitychange", read)
  }, [peer, rows.length, isBlocked])

  const clearPhoto = () => setPhoto(p => { if (p) URL.revokeObjectURL(p.preview); return null })
  useEffect(() => clearPhoto, [peer])
  const attach = async files => {
    const file = [...(files ?? [])].find(isImageFile)
    if (!file || busy || preparing) return
    setStatus(""); setPreparing(true)
    try {
      const ready = await preparePhoto(file)
      clearPhoto()
      setPhoto({ file: ready, preview: URL.createObjectURL(ready) })
    } catch (err) { setStatus(err?.message || "Couldn't read that photo.") } finally { setPreparing(false) }
  }

  const send = async e => {
    e.preventDefault()
    const t = text.trim()
    if ((!t && !photo) || busy || preparing) return
    setBusy(true); setStatus("")
    try {
      let url = null
      if (photo) {
        // The photo first: a message naming a link no server holds would reach them dead.
        try { url = (await uploadPhoto(photo.file, { ctx, servers: await mediaServers(ctx) })).url }
        catch { setStatus("The photo didn't upload, so nothing was sent. Try again."); return }
      }
      const { relays } = await sendMessage(ctx, peer, dmContent(t, url))
      setText(""); clearPhoto()
      const ok = relays.filter(r => r.ok).length
      setStatus(ok === relays.length ? "" : `Sent to ${ok} of ${relays.length} relays`) // delivery to them is checked in sendMessage
    } catch (err) { setStatus(sendFailure(err)) } finally { setBusy(false) }
  }

  return (
    <main class="screen dm-screen">
      <header class="screen-head">
        <button class="small" onClick={() => history.back()}>Back</button>
        <h2 class="dm-title"><Avatar pubkey={peer} size={24} load={follows} /><AuthorName pubkey={peer} /></h2>
        <a class="small button" href={`#/profile/${peer}`}>Profile</a>
      </header>
      {note && <div class="status-line">Your messages can't be read here ({note}).</div>}
      <SignerTrouble trouble={trouble} retry={retry} />
      <AuthTrouble refresh={refresh} />
      <OpenMore ctx={ctx} more={more} />
      {hasLegacy(rows) && <div class="status-line" role="note">Some messages use NIP-04 (legacy encryption). New messages default to NIP-17.</div>}
      {isBlocked && <div class="status-line">You blocked this person on your phone, so their messages are hidden here.</div>}
      <div class="dm-thread">
        {!rows.length && !note && (loaded ? <p class="empty">Start a conversation</p> : <BubbleSkeletons />)}
        {rows.map(m => (
          <div key={m.id} class={m.from === me ? "dm-bubble mine" : "dm-bubble"}>
            {/* depth={1} stops DM text building quote cards, which would query relays the sender names and write
                into /feed; dm keeps video links and nostr:npub as plain text (the iPhone does), and a stranger's
                images wait for a tap. */}
            <NoteText content={m.content} depth={1} dm images={m.from === me || follows} />
            <span class="dm-meta">{ago(m.at)}{m.legacy ? " · NIP-04" : ""}</span>
          </div>
        ))}
        <div ref={end} />
      </div>
      {!note && !isBlocked && (
        <form class={dragging ? "dm-compose dragging" : "dm-compose"} onSubmit={send}
          onDragOver={e => { if ([...(e.dataTransfer?.items ?? [])].some(i => i.kind === "file")) { e.preventDefault(); setDragging(true) } }}
          onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget)) setDragging(false) }}
          onDrop={e => { e.preventDefault(); setDragging(false); attach(e.dataTransfer?.files) }}>
          {photo && (
            <div class="dm-attachment">
              <img src={photo.preview} alt="Photo to send" />
              <button type="button" class="dm-attachment-remove" onClick={clearPhoto} disabled={busy} aria-label="Remove photo">×</button>
            </div>
          )}
          <div class="dm-compose-row">
            <button type="button" class="small dm-photo-button" onClick={() => picker.current?.click()} disabled={busy || preparing} aria-label="Attach photo">{preparing ? "Photo…" : "Photo"}</button>
            <input ref={picker} type="file" accept="image/*" hidden onChange={e => { attach(e.currentTarget.files); e.currentTarget.value = "" }} />
            <textarea ref={field} rows={1} value={text} onInput={e => setText(e.currentTarget.value)} placeholder="Message…" disabled={busy} aria-label="Message"
              onKeyDown={e => { if (sendsOnEnter(e, coarse())) { e.preventDefault(); e.currentTarget.form?.requestSubmit() } }}
              onPaste={e => {
                const files = [...(e.clipboardData?.files ?? [])]
                if (!files.some(isImageFile)) return
                if (!e.clipboardData.getData("text/plain")) e.preventDefault() // text copied with the image still pastes
                attach(files)
              }} />
            <button type="submit" class="primary small" disabled={busy || preparing || (!text.trim() && !photo)} aria-busy={busy || undefined}>{busy ? "Sending…" : "Send"}</button>
          </div>
        </form>
      )}
      {status && <div class="status-line error" role="status">{status}</div>}
    </main>
  )
}

/** Message bubbles, theirs and yours, while the inbox is read: the thread's shape before its words. */
const BubbleSkeletons = () => <>
  <span class="sr-only" role="status">Opening your messages…</span>
  {[["", 58], ["mine", 42], ["", 70], ["mine", 34]].map(([side, w], i) => <div key={i} class={`dm-bubble ${side} skeleton sk-bubble`} style={{ width: `${w}%` }} aria-hidden="true" />)}
</>
