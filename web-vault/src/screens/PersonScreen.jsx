// Someone else's profile (opened from Search): their kind 0, Follow / Unfollow, and their notes, replies, media and
// articles (ProfileTabs.jsx). Notes come
// from their write relays and Haven /feed (net/person.js keeps fetched ones in memory); follows: net/follows.js.
import { useEffect, useState } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { ProfileTabs } from "./ProfileTabs.jsx"
import { ZapButton } from "../components/ZapButton.jsx"
import { MoreMenu, UnblockDialog } from "../components/Moderation.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useProfile } from "../components/useProfile.js"
import { npubEncode } from "nostr-tools/nip19"
import { fetchProfiles } from "../net/profiles.js"
import { followsOf, relation, setFollow } from "../net/follows.js"
import { fetchPersonArticles, fetchPersonLists, readPersonNotes, syncPersonNotes, PERSON_PAGE } from "../net/person.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import "../styles/person.css"

export function PersonScreen({ ctx, pubkey }) {
  const { vault, account, session } = ctx
  const [notes, setNotes] = useState(null)
  const [lists, setLists] = useState(null) // { relays, contacts } once their lists came back
  const [articles, setArticles] = useState(null) // fetched when the Articles tab is first opened
  const [status, setStatus] = useState("")
  const [end, setEnd] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [unblocking, setUnblocking] = useState(false)
  const { blocked } = useBlocks(ctx)
  const isBlocked = blocked.has(pubkey)
  const p = useProfile(pubkey)
  const name = p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"
  const hints = uniq([...account.relays.read, ...DEFAULT_RELAYS])

  useEffect(() => {
    let live = true
    fetchProfiles(vault, [pubkey], uniq([...hints, ...PROFILE_RELAYS])).catch(() => {})
    ;(async () => {
      const cached = await readPersonNotes(vault, pubkey)
      if (!live) return
      setNotes(cached)
      if (!navigator.onLine) return setStatus(cached.length ? "Offline: showing saved notes" : "Offline")
      setStatus(cached.length ? "" : "Fetching notes…")
      const l = await fetchPersonLists(pubkey, hints).catch(() => ({ relays: { write: DEFAULT_RELAYS }, contacts: undefined }))
      if (!live) return
      setLists(l)
      const got = await syncPersonNotes(vault, pubkey, l.relays.write).catch(() => 0)
      if (!live) return
      const fresh = await readPersonNotes(vault, pubkey, { limit: Math.max(PERSON_PAGE, cached.length) })
      setNotes(fresh)
      setEnd(!got && fresh.length < PERSON_PAGE)
      setStatus("")
    })().catch(e => live && setStatus(`Couldn't load notes: ${e?.message ?? e}`))
    return () => { live = false }
  }, [pubkey])

  // Haven first; their relays only when Haven runs short, as the Following feed does.
  const older = async () => {
    const until = notes.at(-1).created_at - 1
    let more = await readPersonNotes(vault, pubkey, { until })
    if (more.length < PERSON_PAGE / 2 && navigator.onLine) {
      setStatus("Fetching older notes…")
      await syncPersonNotes(vault, pubkey, lists?.relays.write ?? DEFAULT_RELAYS, { until }).catch(() => 0)
      more = await readPersonNotes(vault, pubkey, { until })
      setStatus("")
    }
    if (!more.length) setEnd(true)
    setNotes(n => [...n, ...more.filter(m => !n.some(x => x.id === m.id))])
  }

  const loadArticles = async () => {
    if (articles) return
    if (!navigator.onLine) return setArticles([])
    setArticles(await fetchPersonArticles(pubkey, lists?.relays.write ?? DEFAULT_RELAYS).catch(() => []))
  }

  const iFollow = account.follows.includes(pubkey)
  const followsMe = followsOf(lists?.contacts).includes(session.pubkey)
  const toggle = async () => {
    setBusy(true); setErr("")
    try {
      await setFollow({ vault, signer: ctx.signer, pubkey: session.pubkey, target: pubkey, follow: !iFollow,
        readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
      await ctx.reloadAccount()
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : iFollow ? "Unfollowing…" : "Following…") : iFollow ? "Unfollow" : "Follow"

  return (
    <main class="screen">
      <ProfileHeader pubkey={pubkey} you={false} relation={relation(iFollow, followsMe)} follows={lists?.contacts ? followsOf(lists.contacts).length : null}>
        <div class="person-actions">
          {/* Until the user's own list has been read there is nothing safe to build a new one on. */}
          <button class={iFollow ? "follow-btn on" : "follow-btn"} disabled={busy || !account.loaded} onClick={toggle}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true">
              <circle cx="9" cy="8" r="4" /><path d="M2 21c0-3.9 3.1-7 7-7s7 3.1 7 7" />{iFollow ? <path d="M17 11h6" /> : <path d="M20 8v6M17 11h6" />}
            </svg>
            {label}
          </button>
          <ZapButton pubkey={pubkey} />
          <MoreMenu pubkey={pubkey} className="more-btn" />
        </div>
        {err && <p class="error person-error" role="alert">{err}</p>}
      </ProfileHeader>
      {isBlocked && (
        <div class="blocked-banner" role="status">
          <span>You blocked {name}, so their notes are hidden.</span>
          <button type="button" class="small" onClick={() => setUnblocking(true)}>Unblock</button>
          {unblocking && <UnblockDialog ctx={ctx} pubkey={pubkey} name={name} onClose={() => setUnblocking(false)} />}
        </div>
      )}
      {status && !isBlocked && <div class="status-line">{status}</div>}
      {isBlocked ? null : notes === null ? <p class="empty">Opening your relay…</p>
        : <ProfileTabs notes={notes} articles={articles} onTab={id => id === "articles" && loadArticles()}
            empty={status ? { notes: "", replies: "", media: "" } : { notes: "No notes found." }}
            more={!notes.length ? null : end ? <p class="person-end">That's all the notes their relays have.</p> : <button class="more" onClick={older}>Older notes</button>} />}
    </main>
  )
}
