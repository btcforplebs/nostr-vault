// Someone else's profile (opened from Search): their kind 0, Follow / Unfollow, Message, Zap, Web of Trust, and the
// tabs (ProfileTabs.jsx): their notes, media, replies and reposts, the notes that tag them, and their articles. Notes
// come from their write relays and Haven /feed (net/person.js keeps fetched ones in memory); follows: net/follows.js.
import { useEffect, useMemo, useState } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { ProfileTabs, useNoteStream } from "./ProfileTabs.jsx"
import { ZapButton, useWallet } from "../components/ZapButton.jsx"
import { MoreMenu, UnblockDialog } from "../components/Moderation.jsx"
import { ShareProfileButton } from "../components/ShareProfile.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useProfile } from "../components/useProfile.js"
import { npubEncode } from "nostr-tools/nip19"
import { fetchProfiles } from "../net/profiles.js"
import { followsOf, relation, setFollow } from "../net/follows.js"
import { fetchPersonArticles, fetchPersonLists, fetchTagged, openPersonNotes, readPersonNotes, syncPersonNotes, PERSON_PAGE } from "../net/person.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { fetchShop } from "../net/profile-tabs.js"
import "../styles/person.css"

const WOT = "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 10V3.5M13.7 13l5.6 3.5M10.3 13l-5.6 3.5"
const MESSAGE = "M21 12a8 8 0 0 1-11.6 7.1L4 20.5l1.4-5A8 8 0 1 1 21 12z"
/** The WoT tab's globe (TabBar), so the button and the tab read as one place (ProfileActions.trustWeb). */
export const WotButton = ({ pubkey, hint }) => (
  <a class="more-btn" href={pubkey ? `#/wot/${pubkey}` : "#/wot"} aria-label="Web of Trust" title={hint}>
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={WOT} /></svg>
  </a>
)

export function PersonScreen({ ctx, pubkey }) {
  const { vault, account, session } = ctx
  const [lists, setLists] = useState(null) // { relays, contacts } once their lists came back
  const [articles, setArticles] = useState(null)
  const [shop, setShop] = useState(null)
  const [status, setStatus] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [unblocking, setUnblocking] = useState(false)
  const { blocked } = useBlocks(ctx)
  const isBlocked = blocked.has(pubkey)
  const p = useProfile(pubkey)
  const wallet = useWallet()
  const name = p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"
  const hints = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  // Their relay list and follow list, asked for once; the notes, Tagged and Articles all wait on it.
  const listsP = useMemo(() => (navigator.onLine ? fetchPersonLists(pubkey, hints) : Promise.reject(new Error("offline")))
    .catch(() => ({ relays: { read: DEFAULT_RELAYS, write: DEFAULT_RELAYS }, contacts: undefined })), [pubkey])

  useEffect(() => {
    let live = true
    setShop(null)
    fetchProfiles(vault, [pubkey], uniq([...hints, ...PROFILE_RELAYS])).catch(() => {})
    listsP.then(l => {
      if (!live) return
      setLists(l)
      // As the iPhone's ProfileExtrasLoader: fetched at once, so the Articles tab shows only if they have any.
      if (navigator.onLine) fetchPersonArticles(pubkey, l.relays.write).catch(() => []).then(a => live && setArticles(a))
      // Their listings (SellerListingsLoader): the Shop tab shows only if they sell something.
      if (navigator.onLine) fetchShop(pubkey, l.relays.write).catch(() => []).then(s => live && setShop(s))
    })
    return () => { live = false }
  }, [pubkey])

  const notes = useNoteStream(async show => {
    const cached = await readPersonNotes(vault, pubkey)
    show(cached)
    if (!navigator.onLine) { setStatus(cached.length ? "Offline: showing saved notes" : "Offline"); return cached }
    try {
      const got = await openPersonNotes(vault, pubkey, listsP, { show, limit: Math.max(PERSON_PAGE, cached.length) })
      setStatus("")
      return got
    } catch (e) { setStatus(`Couldn't load notes: ${e?.message ?? e}`); return cached }
  }, async until => {
    // Haven first; their relays only when Haven runs short, as the Following feed does.
    let more = await readPersonNotes(vault, pubkey, { until })
    if (more.length < PERSON_PAGE / 2 && navigator.onLine) {
      await syncPersonNotes(vault, pubkey, (await listsP).relays.write, { until }).catch(() => 0)
      more = await readPersonNotes(vault, pubkey, { until })
    }
    return more
  }, [pubkey])
  const tagRelays = async () => uniq([...(await listsP).relays.read, ...hints])
  const tagged = useNoteStream(async () => (navigator.onLine ? fetchTagged(pubkey, await tagRelays()) : []),
    async until => (navigator.onLine ? fetchTagged(pubkey, await tagRelays(), { until }) : []), [pubkey])

  const iFollow = account.follows.includes(pubkey)
  const followsMe = followsOf(lists?.contacts).includes(session.pubkey)
  // Follow as the iPhone's FeedProfileCard: the button changes at once, a toast says so once the list is out, and a tap
  // made while your own follow list is still loading waits for it (nothing safe to build on before) and then runs.
  const [want, setWant] = useState(null) // the follow state asked for and not yet in your list, or null
  const [toast, setToast] = useState("")
  const shown = want ?? iFollow
  const run = async follow => {
    setBusy(true); setErr("")
    try {
      await setFollow({ vault, signer: ctx.signer, pubkey: session.pubkey, target: pubkey, follow,
        readRelays: account.relays.read, writeRelays: account.relays.write, ownRelays: account.relays.listed, known: account.contacts, appCount: account.follows.length })
      await ctx.reloadAccount()
      setToast(follow ? `Following ${name}` : `Unfollowed ${name}`)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false); setWant(null) }
  }
  const toggle = () => {
    if (busy) return
    const follow = !shown
    setWant(follow)
    if (account.loaded) run(follow)
  }
  // The queued tap, once your follow list has been read.
  useEffect(() => { if (account.loaded && want != null && !busy) run(want) }, [account.loaded])
  useEffect(() => { if (!toast) return; const t = setTimeout(() => setToast(""), 2500); return () => clearTimeout(t) }, [toast])
  const label = shown ? "Unfollow" : "Follow"
  const waiting = busy && ctx.signer.method === "nip46" ? "Waiting for your signer…" : want != null && !account.loaded ? "Waiting for your follow list…" : ""

  return (
    <main class="screen">
      <ProfileHeader pubkey={pubkey} you={false} relation={relation(iFollow, followsMe)} follows={lists?.contacts ? followsOf(lists.contacts).length : null}>
        <div class="person-actions">
          {/* Until the user's own list has been read there is nothing safe to build a new one on. */}
          <button class={shown ? "follow-btn on" : "follow-btn"} disabled={busy || ctx.signer?.readOnly} onClick={toggle} aria-busy={busy || want != null || undefined} aria-pressed={shown}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true">
              <circle cx="9" cy="8" r="4" /><path d="M2 21c0-3.9 3.1-7 7-7s7 3.1 7 7" />{shown ? <path d="M17 11h6" /> : <path d="M20 8v6M17 11h6" />}
            </svg>
            {label}
          </button>
          <a class="follow-btn" href={`#/dm/${pubkey}`}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round" aria-hidden="true"><path d={MESSAGE} /></svg>
            Message
          </a>
          {/* Only with a wallet to pay from and an address to pay to (PersonProfileView.actionButtons). */}
          {wallet.status === "ready" && !ctx.signer?.readOnly && !!(p?.lud16 || p?.lud06) && <ZapButton pubkey={pubkey} />}
          <WotButton pubkey={pubkey} hint="Shows how you're connected to them" />
          <ShareProfileButton pubkey={pubkey} />
          <MoreMenu pubkey={pubkey} className="more-btn" />
        </div>
        {waiting && <p class="muted small person-waiting" role="status">{waiting}</p>}
        {err && <p class="error person-error" role="alert">{err}</p>}
      </ProfileHeader>
      {isBlocked && (
        <div class="blocked-banner" role="status">
          <span>You blocked {name}, so their notes are hidden.</span>
          <button type="button" class="small" onClick={() => setUnblocking(true)}>Unblock</button>
          {unblocking && <UnblockDialog ctx={ctx} pubkey={pubkey} name={name} onClose={() => setUnblocking(false)} />}
        </div>
      )}
      {toast && <div class="person-toast" role="status">{toast}</div>}
            {status && !isBlocked && <div class="status-line">{status}</div>}
      {!isBlocked && <ProfileTabs notes={notes} tagged={tagged} articles={articles} shop={shop} pubkey={pubkey} blocked={blocked} />}
    </main>
  )
}
