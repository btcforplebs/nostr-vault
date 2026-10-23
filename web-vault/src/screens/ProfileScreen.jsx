// The user's profile: the tabs (ProfileTabs.jsx) over their notes, replies and reposts, read from Haven's outbox route
// after a network backfill into it and paged further back the same way, the notes that tag them, and their articles.
// Refreshed by its button, or by tapping Profile again while on it (MyProfileView's havenProfileScrollToTop).
import { useEffect, useState } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { ProfileTabs, useNoteStream } from "./ProfileTabs.jsx"
import { WotButton } from "./PersonScreen.jsx"
import { EditProfile } from "./EditProfile.jsx"
import { readOwn, syncOwn } from "../net/sync.js"
import { NOTE_KINDS, fetchTagged, ownOlder, syncOwnPage } from "../net/person.js"
import { parseHash } from "../desktop/routes.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import "../styles/person.css"

const GEAR = "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
const PERSON = "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0"
const REFRESH = "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"
const Icon = ({ d, fill }) => <svg viewBox="0 0 24 24" width="18" height="18" fill={fill ? "currentColor" : "none"} stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
// The opening load, as deep as syncOwn's notes; older pages go PERSON_PAGE at a time.
const OPENING = 300

export function ProfileScreen({ ctx }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const [articles, setArticles] = useState(null)
  const [round, setRound] = useState(0) // bumped by a refresh: the streams and articles load again
  const [editing, setEditing] = useState(false)
  const { blocked } = useBlocks(ctx)
  const writeRelays = uniq([...account.relays.write, ...DEFAULT_RELAYS])

  const notes = useNoteStream(async show => {
    show(await readOwn(vault, me, NOTE_KINDS, OPENING))
    if (navigator.onLine) {
      // syncOwn brings no reposts: they come as deep as its notes, so the newest OPENING read below has no gap.
      await Promise.all([syncOwn(vault, me, writeRelays), syncOwnPage(vault, me, writeRelays, { kinds: [6], limit: OPENING })]).catch(() => {})
    }
    const all = await readOwn(vault, me, NOTE_KINDS, OPENING)
    setArticles(await readOwn(vault, me, [30023], 50))
    return all
  }, until => ownOlder(vault, me, writeRelays, until, { online: navigator.onLine }), [round])
  const tagged = useNoteStream(async () => (navigator.onLine ? fetchTagged(me, uniq([...account.relays.read, ...DEFAULT_RELAYS])) : []),
    async until => (navigator.onLine ? fetchTagged(me, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { until }) : []), [round])

  useEffect(() => { readOwn(vault, me, [30023], 50).then(setArticles).catch(() => {}) }, [])
  const refresh = e => { e?.preventDefault(); setRound(r => r + 1) }

  // Profile tapped again while on it, from the tab bar or the sidebar: back to the top, and from the top, fetched
  // fresh, as the iPhone's tab does. The refresh button in the toolbar is its own click.
  useEffect(() => {
    const again = e => {
      const a = e.target.closest?.('a[href="#/profile"]')
      if (!a || a.closest(".profile-hud")) return
      const { route, arg } = parseHash(location.hash)
      if (route !== "profile" || (arg && arg !== me)) return
      e.preventDefault()
      if (scrollY > 0) scrollTo({ top: 0, behavior: "smooth" })
      else refresh()
    }
    addEventListener("click", again, true)
    return () => removeEventListener("click", again, true)
  }, [])

  if (editing) return <EditProfile ctx={ctx} onClose={() => { setEditing(false); scrollTo({ top: 0 }) }} />
  return (
    <main class="screen">
      {/* The phone's Profile toolbar: the Wallet on the left, Refresh and Settings on the right, over the banner. */}
      <header class="screen-head profile-hud">
        <a class="vault-pill-btn hud-accent" href="#/wallet" aria-label="Wallet" title="Wallet"><Icon d="M13 2L4 14h7l-1 8 9-12h-7z" fill /></a>
        <span class="hud-title" aria-hidden="true">Profile</span>
        <div class="vault-right">
          <a class="vault-pill-btn" href="#/profile" role="button" aria-label="Refresh" title="Refresh" aria-busy={notes.opening || undefined} onClick={refresh}><Icon d={REFRESH} /></a>
          <a class="vault-pill-btn" href="#/settings" aria-label="Settings" title="Settings"><Icon d={GEAR} /></a>
        </div>
      </header>
      <ProfileHeader pubkey={me} follows={account.follows.length}>
        <div class="person-actions">
          {/* A read-only sign-in can't sign a kind 0, so it gets no Edit Profile. */}
          {!ctx.signer?.readOnly && <button type="button" class="follow-btn" onClick={() => { setEditing(true); scrollTo({ top: 0 }) }}><Icon d={PERSON} />Edit Profile</button>}
          <WotButton hint="Shows your web of trust" />
        </div>
      </ProfileHeader>
      <ProfileTabs notes={notes} tagged={tagged} articles={articles} pubkey={me} blocked={blocked} />
    </main>
  )
}
