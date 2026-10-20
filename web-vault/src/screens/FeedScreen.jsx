// The Feed, with the picker (net/feeds.js). Following and Media are rendered only from Haven /feed; the network fills
// /feed in the background. Global, Hashtag and Popular come from the network into memory only: strangers' notes never
// go into /feed.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { feedList, loadChoice, saveChoice, normalizeTag, fetchStrangerFeed, mergePage, statusGate, heldNotes, holdNotes, noteAuthors, feedKey, fromHaven } from "../net/feeds.js"
import { fetchPopular } from "../net/popular.js"
import { mediaTiles } from "../net/media.js"
import { READERS } from "../readers/index.js"

if (import.meta.env) import("../styles/feeds.css")

const PAGE = 100
const MEDIA_PAGE = 300 // most notes have no media, so Media reads more at a time (the iPhone asks for 300)
const FEEDS = feedList(READERS)
const readerFor = mode => READERS.find(r => r.id === mode)
const pickedChoice = () => loadChoice(globalThis.localStorage, FEEDS)

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  const [status, setStatus] = useState("")
  const [syncing, setSyncing] = useState(false)
  const { blocked, privateNote } = useBlocks(ctx)
  const [choice, setChoice] = useState(pickedChoice)
  const [strange, setStrange] = useState(() => heldNotes(pickedChoice()))
  // A reader (Articles, Live, …) draws its own list under the picker; the notes below are not loaded for it.
  const Reader = readerFor(choice.mode)?.Screen
  const following = fromHaven(choice.mode), media = choice.mode === "media", popular = choice.mode === "popular"
  const page = media ? MEDIA_PAGE : PAGE
  // A sync started on Following reloads when it ends, maybe after a switch to Media: it reads with the page size
  // and note count of the feed shown then, not of the render that started it.
  const shownNow = useRef({})
  shownNow.current = { page, have: notes?.length ?? 0 }
  // One number per feed shown: picking a feed or starting a stranger load bumps it, and work started under an older
  // number (a Following sync, a Global page) no longer writes the status line.
  const seq = useRef(0)
  const pick = c => { seq.current++; saveChoice(c); setChoice(c); setStrange(heldNotes(c)); setStatus("") }
  const sayer = () => statusGate(seq, setStatus)

  const reload = async () => setNotes(await readFeed(vault, follows, { limit: Math.max(shownNow.current.page, shownNow.current.have) }))
  const sync = async () => {
    // No follow list yet (still loading, or nobody followed): there is nothing to sync, so nothing is "up to date".
    const say = sayer()
    if (!follows.length) return say("")
    if (!navigator.onLine) return say("Offline: showing your saved feed")
    say("Syncing…")
    setSyncing(true)
    // Show notes as each chunk of follows lands, not after the last one. Reloads queue so an older read can't
    // land after a newer one.
    let shown = Promise.resolve(), seen = 0
    try {
      const n = await syncFeed(vault, follows, relays, { onProgress: p => {
        say(`Syncing ${p.done}/${p.of} follows · ${p.stored} saved`)
        if (p.stored > seen) { seen = p.stored; shown = shown.then(reload) }
      } })
      await shown
      await reload()
      say(n ? `${n} notes saved to your relay` : "Up to date")
    } catch (e) { say(`Sync failed (${e?.message ?? e}): showing your saved feed`) }
    finally { setSyncing(false) }
  }
  const older = async () => {
    const say = sayer()
    const until = notes.at(-1)?.created_at - 1
    let more = await readFeed(vault, follows, { limit: page, until })
    if (more.length < page / 2 && navigator.onLine) {
      say("Fetching older notes…")
      for (let i = 0; i < follows.length; i += 250) {
        const evs = await pool.querySync(relays, { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), until, limit: 200 }, { maxWait: 8000 })
        for (const ev of evs) await vault.feed.event(ev)
      }
      more = await readFeed(vault, follows, { limit: page, until })
      say("")
    }
    setNotes([...notes, ...more])
  }

  // Global, Hashtag and Popular. Each load is for one feed: once the picker has moved on, a late answer is dropped.
  const loadStrange = async (c, until) => {
    const n = ++seq.current
    if (c.mode === "hashtag" && !c.tag) return setStatus("")
    if (c.mode === "popular" && !follows.length) return setStatus("")
    if (!navigator.onLine) return setStatus(`Offline: ${FEEDS.find(f => f.id === c.mode).label} needs the network`)
    setStatus(until ? "Fetching older notes…" : c.mode === "popular" ? "Ranking the last day's likes, reposts and zaps…" : "Loading…")
    try {
      const page = c.mode === "popular"
        ? (await fetchPopular({ me: ctx.session?.pubkey, follows, relays, vault, blocked })).notes
        : await fetchStrangerFeed(c, account.relays.read, { until })
      if (n !== seq.current) return
      const all = until ? mergePage(heldNotes(c) ?? [], page) : page
      holdNotes(c, all)
      setStrange(all)
      setStatus(page.length ? "" : until ? "No older notes found" : "")
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }

  useEffect(() => { if (following) reload().then(sync) }, [follows.length, following])
  // Following and Media share the notes read from /feed; Media reads a bigger page, so switching to it reads again.
  useEffect(() => { if (following && notes) reload() }, [media])
  useEffect(() => { if (!Reader && !following && !heldNotes(choice)) loadStrange(choice) }, [feedKey(choice), popular && follows.length > 0])
  useEffect(() => {
    if (following && notes?.length) fetchProfiles(vault, noteAuthors(notes), relays).catch(() => {})
  }, [notes, following])
  useEffect(() => {
    if (!following && strange?.length) fetchProfiles(vault, noteAuthors(strange), account.relays.read, { save: false }).catch(() => {})
  }, [strange, following])

  // Blocked people's notes stay where they are and are only left out here, so unblocking brings them back.
  const list = following ? notes : strange
  const shown = list && visibleNotes(list, blocked)
  const tiles = media && shown && mediaTiles(shown)
  const label = FEEDS.find(f => f.id === choice.mode).label
  return (
    <main class="screen">
      <header class="screen-head">
        <h2>{choice.mode === "hashtag" && choice.tag ? `#${choice.tag}` : label}</h2>
        {!Reader && <button class="small" onClick={() => (following ? sync() : loadStrange(choice))}>Refresh</button>}
      </header>
      <FeedPicker choice={choice} onPick={pick} />
      {Reader ? <Reader ctx={ctx} /> : <>
      {status && <div class="status-line">{status}</div>}
      {privateNote && !ctx.signer?.readOnly && <div class="status-line">Your private blocks weren't read ({privateNote}), so those people may still show.</div>}
      {following
        ? !follows.length ? <p class="empty">{account.loaded ? "You don't follow anyone yet." : "Loading your follows…"}</p>
          : notes === null ? <p class="empty">Opening your relay…</p>
          : !notes.length ? <p class="empty">{syncing ? "Fetching notes from the people you follow…" : "No notes saved yet."}</p>
          : media ? <Media tiles={tiles} blockedAll={!shown.length} onOlder={older} />
          : <Notes shown={shown} onOlder={older} />
        : choice.mode === "hashtag" && !choice.tag ? <p class="empty">Type a hashtag to see notes tagged with it.</p>
          : popular && !follows.length ? <p class="empty">{account.loaded ? "Popular counts what the people you follow, and the people they follow, liked. Follow someone first." : "Loading your follows…"}</p>
          : strange === null ? <p class="empty">{navigator.onLine ? "Loading notes…" : "This feed needs the network."}</p>
          : !strange.length ? <p class="empty">{popular ? "Nothing popular in the last day yet: a note needs likes, reposts or zaps from three people your follows follow." : "No notes found."}</p>
          : <Notes shown={shown} memoryOnly onOlder={popular ? null : () => loadStrange(choice, strange.at(-1)?.created_at - 1)} />}
      </>}
    </main>
  )
}

/** The notes left after blocks, then Older (none for Popular, which is one ranked page). When every loaded note is
 *  from someone blocked, say so above Older. `memoryOnly`: strangers' notes, so their cards write nothing to /feed. */
export function Notes({ shown, onOlder, memoryOnly = false }) {
  return <>
    {shown.length ? shown.map(n => <NoteCard key={n.id} event={n} memoryOnly={memoryOnly} />)
      : <p class="empty">Every note loaded here is from someone you blocked.</p>}
    {onOlder && <button class="more" onClick={onOlder}>Older notes</button>}
  </>
}

/** The Media grid, then Older. Most notes have none, so an empty grid says why and still offers Older. */
export function Media({ tiles, blockedAll, onOlder }) {
  return <>
    {tiles.length ? <MediaGrid tiles={tiles} />
      : <p class="empty">{blockedAll ? "Every note loaded here is from someone you blocked." : "No photos or videos in the notes loaded so far."}</p>}
    <button class="more" onClick={onOlder}>Older notes</button>
  </>
}

/** The feeds, and the tag box when Hashtag is picked. */
function FeedPicker({ choice, onPick }) {
  const [draft, setDraft] = useState(choice.tag)
  const submit = e => { e.preventDefault(); const tag = normalizeTag(draft); setDraft(tag); onPick({ mode: "hashtag", tag }) }
  return (
    <div class="feed-picker">
      <div class="feed-modes" role="tablist" aria-label="Feed">
        {FEEDS.map(f => (
          <button key={f.id} type="button" role="tab" aria-selected={choice.mode === f.id} class={choice.mode === f.id ? "on" : ""}
            onClick={() => onPick({ mode: f.id, tag: choice.tag })}>{f.label}</button>
        ))}
      </div>
      {choice.mode === "hashtag" && (
        <form class="feed-tag" onSubmit={submit}>
          <input type="search" value={draft} onInput={e => setDraft(e.currentTarget.value)} placeholder="#bitcoin" aria-label="Hashtag"
            enterkeyhint="go" autocapitalize="off" autocorrect="off" spellcheck={false} />
          <button type="submit" class="small">Show</button>
        </form>
      )}
    </div>
  )
}
