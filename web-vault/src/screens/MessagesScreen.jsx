// Messages: the user's conversations, newest first (iPhone DMInboxView). Read from Haven's /chat and the relays
// through net/dms.js; the text is decrypted in memory only. Blocked people's conversations are left out.
import { useEffect, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { conversations, dmRelaysFor, extraRelays, forgetUnopened, getMessages, loadMessages, onMessages, openMore, watchMessages } from "../net/dms.js"

/** The relays the user's own DMs are read from: their DM inbox list, read list, defaults and this browser's extras. */
export async function inboxRelays(ctx) {
  const { read, write } = ctx.account.relays
  const lookup = uniq([...read, ...write, ...DEFAULT_RELAYS])
  const mine = await dmRelaysFor(ctx.session.pubkey, lookup, { fallback: [] }).catch(() => [])
  return uniq([...mine, ...read, ...DEFAULT_RELAYS, ...extraRelays()])
}

/** Messages state for a screen, loading once and re-rendering as messages land. `retry` asks again for every message
 *  that isn't open (the signer refused or stopped answering: `trouble`). */
export function useMessages(ctx) {
  const [m, setM] = useState(getMessages)
  const [round, setRound] = useState(0)
  useEffect(() => {
    const off = onMessages(() => setM(getMessages()))
    let stop = () => {}
    let live = true
    ;(async () => {
      const relays = await inboxRelays(ctx)
      if (!live) return
      await loadMessages(ctx, relays).catch(() => {})
      if (live) stop = watchMessages(ctx, relays)
    })()
    return () => { live = false; off(); stop() }
  }, [ctx.session.pubkey, round])
  return { ...m, retry: () => { forgetUnopened(); setRound(r => r + 1) } }
}

/** Messages past the first load's ceiling, or that came in faster than they're opened live: open the next lot. */
export function OpenMore({ ctx, more }) {
  const [busy, setBusy] = useState(false)
  if (!more) return null
  const go = async () => { setBusy(true); try { await openMore(ctx) } finally { setBusy(false) } }
  return (
    <div class="status-line">
      {more === 1 ? "1 more message isn't open yet." : `${more} more messages aren't open yet.`}{" "}
      <button type="button" class="small" disabled={busy} onClick={go}>{busy ? (ctx.session.method === "nip46" ? "Waiting for your signer…" : "Opening…") : "Open more"}</button>
    </div>
  )
}

/** With a bunker, the bunker decrypts and encrypts message text for the page, so it sees that text. Said once, plainly. */
export function BunkerNote({ ctx }) {
  if (ctx.session.method !== "nip46") return null
  return <p class="status-line muted small">Your bunker opens and seals your messages for this page, so the bunker app sees their text.</p>
}

/** The signer stopped answering while messages were being opened: say so, and offer to ask again. */
export function SignerTrouble({ trouble, retry }) {
  if (!trouble) return null
  return (
    <div class="status-line error" role="alert">
      Some messages aren't open yet: {trouble} <button type="button" class="small" onClick={retry}>Try again</button>
    </div>
  )
}

export function MessagesScreen({ ctx }) {
  const { messages, note, trouble, retry, more, loaded } = useMessages(ctx)
  const { blocked } = useBlocks(ctx)
  const [to, setTo] = useState("")
  const [err, setErr] = useState("")
  const list = conversations(messages, blocked)

  useEffect(() => {
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
    fetchProfiles(ctx.vault, list.map(c => c.peer), relays).catch(() => {})
  }, [list.map(c => c.peer).join()])

  const open = e => {
    e.preventDefault()
    const pk = pubkeyOf(to.trim())
    if (!pk) return setErr("Paste an npub, nprofile or hex public key.")
    setErr(""); setTo("")
    location.hash = `#/dm/${pk}`
  }

  return (
    <main class="screen">
      <header class="screen-head"><h2>Messages</h2></header>
      {note && <div class="status-line">Your messages can't be read here ({note}).</div>}
      <BunkerNote ctx={ctx} />
      <SignerTrouble trouble={trouble} retry={retry} />
      <OpenMore ctx={ctx} more={more} />
      <form class="dm-new" onSubmit={open}>
        <input value={to} onInput={e => setTo(e.currentTarget.value)} placeholder="New message to npub…" autocapitalize="off" autocorrect="off" spellcheck={false} aria-label="New message to" />
        <button type="submit" class="small" disabled={!to.trim()}>Open</button>
      </form>
      {err && <div class="status-line error">{err}</div>}
      {!loaded && !list.length ? <p class="empty">Opening your messages…{ctx.session.method === "nip46" ? " Your signer may ask you to approve." : ""}</p>
        : !list.length ? <p class="empty">{note ? "" : "No messages yet."}</p>
        : list.map(c => (
          <a key={c.peer} class="dm-row" href={`#/dm/${c.peer}`}>
            {/* A stranger's picture waits: their server would learn your IP the moment the list draws. */}
            <Avatar pubkey={c.peer} size={44} load={ctx.account.follows.includes(c.peer)} />
            <span class="dm-row-text">
              <span class="dm-row-head"><AuthorName pubkey={c.peer} /><time class="note-time" datetime={new Date(c.last.at * 1000).toISOString()}>{ago(c.last.at)}</time></span>
              <span class="dm-row-last">{c.last.from === ctx.session.pubkey ? "You: " : ""}{c.last.content.replace(/\s+/g, " ").trim() || "(empty)"}</span>
            </span>
          </a>
        ))}
    </main>
  )
}

/** npub / nprofile / 64-hex -> hex pubkey, else null. */
export function pubkeyOf(s) {
  if (/^[0-9a-f]{64}$/i.test(s)) return s.toLowerCase()
  try {
    const d = decode(s.replace(/^nostr:/, ""))
    if (d.type === "npub") return d.data
    if (d.type === "nprofile") return d.data.pubkey
  } catch {}
  return null
}
