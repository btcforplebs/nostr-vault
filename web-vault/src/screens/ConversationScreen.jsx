// One conversation (iPhone DMThreadView): their messages on the left, the user's on the right, a field and Send at
// the bottom. Sending is NIP-17 through net/dms.js; the sent text shows at once and stays in memory only.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { sendMessage, sendFailure, thread } from "../net/dms.js"
import { useMessages, SignerTrouble, OpenMore } from "./MessagesScreen.jsx"

export function ConversationScreen({ ctx, peer }) {
  const { messages, note, trouble, retry, more } = useMessages(ctx)
  const { blocked } = useBlocks(ctx)
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const end = useRef(null)
  const me = ctx.session.pubkey
  const rows = thread(messages, peer)
  const isBlocked = blocked.has(peer)

  useEffect(() => { fetchProfiles(ctx.vault, [peer], uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {}) }, [peer])
  useEffect(() => { end.current?.scrollIntoView?.({ block: "end" }) }, [rows.length])

  const send = async e => {
    e.preventDefault()
    const t = text.trim()
    if (!t || busy) return
    setBusy(true); setStatus("")
    try {
      const { relays } = await sendMessage(ctx, peer, t)
      setText("")
      const ok = relays.filter(r => r.ok).length
      setStatus(ok === relays.length ? "" : `Sent to ${ok} of ${relays.length} relays`) // delivery to them is checked in sendMessage
    } catch (err) { setStatus(sendFailure(err)) } finally { setBusy(false) }
  }

  return (
    <main class="screen dm-screen">
      <header class="screen-head">
        <button class="small" onClick={() => history.back()}>Back</button>
        <h2 class="dm-title"><Avatar pubkey={peer} size={24} /><AuthorName pubkey={peer} /></h2>
        <a class="small button" href={`#/profile/${peer}`}>Profile</a>
      </header>
      {note && <div class="status-line">Your messages can't be read here ({note}).</div>}
      <SignerTrouble trouble={trouble} retry={retry} />
      <OpenMore ctx={ctx} more={more} />
      {isBlocked && <div class="status-line">You blocked this person on your phone, so their messages are hidden here.</div>}
      <div class="dm-thread">
        {!rows.length && !note && <p class="empty">No messages with {npubEncode(peer).slice(0, 12)}… yet.</p>}
        {rows.map(m => (
          <div key={m.id} class={m.from === me ? "dm-bubble mine" : "dm-bubble"}>
            {/* depth={1} stops DM text building quote cards, which would query relays the sender names and write
                into /feed; dm keeps video links and nostr:npub as plain text (the iPhone does), images still show. */}
            <NoteText content={m.content} depth={1} dm />
            <span class="dm-meta">{ago(m.at)}{m.legacy ? " · NIP-04" : ""}</span>
          </div>
        ))}
        <div ref={end} />
      </div>
      {!note && !isBlocked && (
        <form class="dm-compose" onSubmit={send}>
          <input value={text} onInput={e => setText(e.currentTarget.value)} placeholder="Message…" disabled={busy} aria-label="Message" />
          <button type="submit" class="primary small" disabled={busy || !text.trim()}>{busy ? "Sending…" : "Send"}</button>
        </form>
      )}
      {status && <div class="status-line error" role="status">{status}</div>}
    </main>
  )
}
