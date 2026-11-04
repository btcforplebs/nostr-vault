// Messages: the user's conversations, newest first (iPhone DMInboxView). Read from Haven's /chat and the relays
// through net/dms.js; the text is decrypted in memory only. Blocked people's conversations are left out. Unread
// conversations are bold with a count, as on the iPhone (net/dm-read.js). People outside the user's Web of Trust
// whom the user never wrote to wait under Requests (net/dm-trust.js, the iPhone's DMTrust): the tray button at the top
// right opens them at #/messages/requests, and they never count towards an unread badge. The search runs on this
// device only (MessagesTools.jsx, net/dm-search.js). The title is for screen readers only, so the buttons have room.
import { useEffect, useRef, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { MentionPicker } from "../components/MentionPicker.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { markRead, onRead, unreadCounts } from "../net/dm-read.js"
import { forgetDeclinedAuth, getAuthProblems, onAuthProblems } from "../net/dm-read-auth.js"
import { conversations, extraRelays, ownDmRelays, needResync, RELAY_CACHE_MS, loadedRecently, forgetUnopened, getMessages, lastPreview, loadMessages, onMessages, openMore, claimResync, onResyncNeeded, watchMessages } from "../net/dms.js"
import { SkeletonList } from "../components/Loading.jsx"
import { hiddenFromUnread, useDmTrust } from "../components/useDmTrust.js"
import { searchChats } from "../net/dm-search.js"
import { RequestsButton, MessagesSearch, searchName } from "./MessagesTools.jsx"
import { splitConversations } from "../net/dm-trust.js"
import { VaultPagesMenu } from "./VaultPagesMenu.jsx"

// The people strip under "New message" is the composer's @mention picker; its styles come with it.
if (import.meta.env) import("../styles/compose.css")

/** The relays the user's own DMs are read from: their DM inbox list, read list, defaults and this browser's extras. */
export async function inboxRelays(ctx) {
  const { read, write } = ctx.account.relays
  const lookup = uniq([...read, ...write, ...DEFAULT_RELAYS])
  const mine = await ownInbox(ctx.session.pubkey, lookup).catch(() => [])
  return uniq([...mine, ...read, ...DEFAULT_RELAYS, ...extraRelays()])
}

// The own inbox lookup, kept like cachedDmRelays (RELAY_CACHE_MS): the first look settles early (ownDmRelays), later
// ones get the full answer. An inbox relay only a slow relay knew about makes the screens look again (needResync).
const ownLookups = new Map() // pubkey -> { at, full, early }
function ownInbox(pubkey, lookup) {
  const hit = ownLookups.get(pubkey)
  if (hit && Date.now() - hit.at < RELAY_CACHE_MS) return hit.done ? hit.full : hit.early
  const { early, full } = ownDmRelays(pubkey, lookup, { onLater: needResync })
  const entry = { at: Date.now(), early, full, done: false }
  full.then(() => { entry.done = true }, () => { if (ownLookups.get(pubkey) === entry) ownLookups.delete(pubkey) })
  ownLookups.set(pubkey, entry)
  return early
}

let lastDrop = null

/** Messages state for a screen, loading once and re-rendering as messages land. `refresh` (the iPhone's pull to
 *  refresh) looks at the relays again; `retry` also asks again for every message that isn't open (the signer refused
 *  or stopped answering: `trouble`). Coming back to the tab after five minutes, or back online, looks again
 *  too (DMService.syncOnForeground / reconnect), with a fresh live subscription. `syncing` while a look is running. */
export function useMessages(ctx) {
  const [m, setM] = useState(getMessages)
  const [round, setRound] = useState(0)
  const [syncing, setSyncing] = useState(false)
  useEffect(() => {
    const off = onMessages(() => setM(getMessages()))
    let stop = () => {}
    let live = true
    ;(async () => {
      const relays = inboxRelays(ctx) // looked up while Haven's copies open (loadMessages)
      // Opening a screen right after a load (list -> conversation -> back) keeps what's held and only listens.
      if (round === 0 && loadedRecently(ctx.session.pubkey)) { const r = await relays; if (live) stop = watchMessages(ctx, r); return }
      setSyncing(true)
      try {
        await loadMessages(ctx, relays).catch(() => {})
        if (live) stop = watchMessages(ctx, await relays)
      } finally { if (live) setSyncing(false) }
    })()
    return () => { live = false; off(); stop() }
  }, [ctx.session.pubkey, round])
  useEffect(() => {
    // Both screens may be mounted (desktop list + thread): claimResync lets only one of them look.
    const back = () => { if (document.visibilityState === "visible" && claimResync()) setRound(r => r + 1) }
    const online = () => { if (claimResync({ after: 10_000 })) setRound(r => r + 1) }
    // A relay dropped after a failed AUTH (dms.js) took its live subscription with it: look again at once. Each drop
    // hands every listener the same list, so with both screens mounted only the first one looks.
    const dropped = urls => { if (urls === lastDrop) return; lastDrop = urls; setRound(r => r + 1) }
    const offDropped = onResyncNeeded(dropped)
    document.addEventListener("visibilitychange", back)
    addEventListener("online", online)
    return () => { offDropped(); document.removeEventListener("visibilitychange", back); removeEventListener("online", online) }
  }, [])
  // `refresh` (AuthTrouble's Sign in again) looks again without forgetting what was settled: wraps found not to be the user's, and ones refused past
  // MAX_REFUSALS, stay settled, so a routine tap never costs a bunker user a run of prompts. Only "Try again" does.
  // Both also ask again about an inbox whose AUTH was declined; a return to the tab doesn't (dm-read-auth.js).
  const retry = () => { forgetUnopened(); forgetDeclinedAuth(); setRound(r => r + 1) }
  return { ...m, syncing, retry, refresh: () => { forgetDeclinedAuth(); setRound(r => r + 1) } }
}

/** Unread counts per conversation, re-counted as messages land or are read. `total` leaves Requests out (they are
 *  unread but silent). -> { counts: Map peer -> n, total } */
export function useUnread(ctx, messages, blocked, trusted = new Set()) {
  const [, setTick] = useState(0)
  useEffect(() => onRead(() => setTick(t => t + 1)), [])
  const counts = unreadCounts(messages, ctx.session.pubkey, blocked)
  const hidden = hiddenFromUnread(messages, ctx.session.pubkey, blocked, trusted)
  let total = 0
  for (const [peer, n] of counts) if (!hidden.has(peer)) total += n
  return { counts, total }
}

/** Whether the address is the Requests list ("#/messages/requests", maybe with a desktop "?dm="). */
export const isRequestsHash = (hash = location.hash) => /^#\/?messages\/requests(\?|$)/.test(hash)

/** Messages past the first load's ceiling, or that came in faster than they're opened live: open the next lot. */
export function OpenMore({ ctx, more }) {
  const [busy, setBusy] = useState(false)
  if (!more) return null
  const go = async () => { setBusy(true); try { await openMore(ctx) } finally { setBusy(false) } }
  return (
    <div class="status-line">
      {more === 1 ? "1 more message isn't open yet." : `${more} more messages aren't open yet.`}{" "}
      <button type="button" class="small" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? (ctx.session.method === "nip46" ? "Waiting for your signer…" : "Opening…") : "Open more"}</button>
    </div>
  )
}

/** With a bunker, the bunker decrypts and encrypts message text for the page, so it sees that text. Said once, plainly. */
export function BunkerNote({ ctx }) {
  if (ctx.session.method !== "nip46") return null
  return <p class="status-line muted small">Your bunker opens and seals your messages for this page, so the bunker app sees their text.</p>
}

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** A relay that wanted a sign-in before showing messages and didn't get one (dm-read-auth.js): say which, in our
 *  words, with Sign in again to ask again (the only way it is asked again: a declined sign-in isn't asked on its own). */
export function AuthTrouble({ refresh }) {
  const [problems, setProblems] = useState(getAuthProblems)
  useEffect(() => onAuthProblems(() => setProblems(getAuthProblems())), [])
  if (!problems.length) return null
  return (
    <div class="status-line error" role="alert">
      {problems.map(({ url, kind }) => (
        <span key={url} class="dm-auth-problem">
          {kind === "declined"
            ? `${hostOf(url)} asks you to sign in before it shows your messages, and your signer didn't. `
            : `${hostOf(url)} turned down your sign-in, so messages kept there can't be read here. `}
        </span>
      ))}
      <button type="button" class="small" onClick={refresh}>Sign in again</button>
    </div>
  )
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

/** `vaultMenu`: the phone's Messages page, one of the Vault's pages, wears the Vault menu top left (VaultPagesMenu.jsx).
 *  The desktop's Messages column (DesktopShell) doesn't: there Messages is a rail row. */
export function MessagesScreen({ ctx, vaultMenu = false }) {
  const { messages, note, trouble, retry, refresh, more, loaded } = useMessages(ctx)
  const { blocked } = useBlocks(ctx)
  const [to, setTo] = useState("")
  const [err, setErr] = useState("")
  const toBox = useRef(null)
  const [people, setPeople] = useState(false) // the people strip: open while the box has focus, until Escape
  const trusted = useDmTrust(ctx)
  const me = ctx.session.pubkey
  const { inbox, requests } = splitConversations(conversations(messages, blocked), messages, me, trusted)
  const showRequests = isRequestsHash()
  const [query, setQuery] = useState("")
  useEffect(() => setQuery(""), [showRequests]) // a search is for the list it was typed over
  const all = showRequests ? requests : inbox
  const list = searchChats(all, messages, query, searchName)
  const inboxPeers = new Set(inbox.map(c => c.peer))
  // Only a name is looked up: a key (whole or mistyped) or an address would tell the search relays who you mean to write to.
  const showPeople = people && peopleQuery(to)
  const { counts, total } = useUnread(ctx, messages, blocked, trusted)

  useEffect(() => {
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
    fetchProfiles(ctx.vault, all.map(c => c.peer), relays).catch(() => {})
  }, [all.map(c => c.peer).join()])

  const open = e => {
    e.preventDefault()
    const pk = pubkeyOf(to.trim())
    if (!pk) return setErr("Pick someone from the list, or paste an npub, nprofile or hex public key.")
    setErr(""); setTo("")
    location.hash = `#/dm/${pk}`
  }

  return (
    <main class="screen">
      <header class="screen-head dm-head">
        {showRequests ? <a class="small button" href="#/messages">‹ Messages</a> : vaultMenu && <VaultPagesMenu ctx={ctx} current="messages" />}
        <h2 class={showRequests ? undefined : "sr-only"}>{showRequests ? "Requests" : "Messages"}</h2>
        <span class="dm-head-actions">
          {!showRequests && total > 0 && <button type="button" class="small" onClick={() => markRead(me, [...messages.values()].filter(m => inboxPeers.has(m.peer)))}>Mark all read</button>}
          {!showRequests && <RequestsButton count={requests.length} />}
        </span>
      </header>
      {note && <div class="status-line">Your messages can't be read here ({note}).</div>}
      <BunkerNote ctx={ctx} />
      <SignerTrouble trouble={trouble} retry={retry} />
      <AuthTrouble refresh={refresh} />
      <OpenMore ctx={ctx} more={more} />
      {!showRequests && <form class="dm-new" onSubmit={open}>
        <input ref={toBox} value={to} onInput={e => { setTo(e.currentTarget.value); setErr(""); setPeople(true) }}
          onFocus={() => setPeople(true)} onBlur={() => setPeople(false)} placeholder="New message to a name or npub…" autocapitalize="off" autocorrect="off" spellcheck={false}
          aria-label="New message to" aria-controls={showPeople ? "mention-picker" : undefined} />
        <button type="submit" class="small" disabled={!to.trim()}>Open</button>
      </form>}
      {/* MessageComposerView's search: people by name (follows first, then a NIP-50 search), picked to open the thread. */}
      {showPeople && (
        <div class="dm-people">
          <MentionPicker ctx={ctx} query={to.trim()} input={toBox} onClose={() => setPeople(false)}
            onPick={pk => { setTo(""); setErr(""); location.hash = `#/dm/${pk}` }} />
        </div>
      )}
      {err && <div class="status-line error">{err}</div>}
      {all.length > 0 && <MessagesSearch value={query} onInput={setQuery} label={showRequests ? "Search requests" : "Search messages"} />}
      {showRequests && <p class="status-line muted small">From people outside your Web of Trust. Replying moves a conversation to Messages.</p>}
      {!loaded && !all.length ? <>
          {ctx.session.method === "nip46" && <p class="status-line">Your signer may ask you to approve.</p>}
          <SkeletonList rowClass="dm-row" avatar={44} label="Opening your messages…" />
        </>
        : query && all.length && !list.length ? <div class="empty"><strong>No matches</strong><p class="small">Nothing in your {showRequests ? "requests" : "messages"} matches “{query.trim()}”.</p></div>
        : !list.length ? (note ? null : showRequests ? <div class="empty"><strong>No Requests</strong></div> : (
          // DMInboxView's empty state; the web composer is the "New message to" box above, not a button.
          <div class="empty"><strong>No Messages Yet</strong><p class="small">{requests.length ? <>Start an encrypted conversation with New message above.<br />Requests from people outside your Web of Trust are behind the tray at the top.</> : <>Start an encrypted conversation<br />with New message above</>}</p></div>
        ))
        : list.map(c => { const unread = counts.get(c.peer) ?? 0; return (
          <a key={c.peer} class={unread ? "dm-row unread" : "dm-row"} href={`#/dm/${c.peer}`} aria-label={unread ? `${unread} unread` : undefined}>
            {/* A stranger's picture waits: their server would learn your IP the moment the list draws. As DMInboxView's
                row: an unread dot on the face, the time in the accent while unread, the count only past 1, two lines. */}
            <span class="dm-avatar"><Avatar pubkey={c.peer} size={44} load={ctx.account.follows.includes(c.peer)} />{unread > 0 && <span class="dm-dot" aria-hidden="true" />}</span>
            <span class="dm-row-text">
              <span class="dm-row-head"><AuthorName pubkey={c.peer} /><time class="note-time dm-time" datetime={new Date(c.last.at * 1000).toISOString()}>{ago(c.last.at)}</time></span>
              <span class="dm-row-foot">
                <span class="dm-row-last">{(c.hit ?? c.last).from === ctx.session.pubkey ? "You: " : ""}{lastPreview((c.hit ?? c.last).content)}</span>
                {unread > 1 && <span class="dm-unread">{unread > 99 ? "99+" : unread}</span>}
              </span>
            </span>
          </a>
        ) })}
      {showRequests && list.length > 0 && <p class="status-line muted small">These people are outside your Web of Trust, so their messages never notify you. Reply to move a conversation to your inbox.</p>}
    </main>
  )
}

/** Whether what's in "New message" is a name to look up: not a key, a near-key or an address. */
export const peopleQuery = s => {
  const q = String(s ?? "").trim()
  return !!q && !/^(npub1|nprofile1|nostr:)/i.test(q) && !/^[0-9a-f]{8,}$/i.test(q) && !q.includes("@") && !pubkeyOf(q)
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
