// The Polls feed (parity #18; iPhone PollsFeedViews.swift): Following or Global, then Open / Closed / All, each poll
// drawn as the feed draws one (NoteCard's poll body: vote, results, closing time). The status only re-filters what is
// loaded, as on the phone.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { visibleNotes } from "../net/blocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { SkeletonRows } from "../components/FeedExtras.jsx"
import { Scopes } from "./ArticlesScreen.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { POLL_SCOPES, POLL_STATUSES, PAGE, fetchPolls, loadPollScope, savePollScope, statusAdmits, emptyText } from "./polls.js"

if (import.meta.env) import("./readers.css")

export function PollsScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadPollScope)
  const [status, setStatus] = useState("all") // this visit only, as the phone's pollStatusFilter
  const [items, setItems] = useState(null)
  const [line, setLine] = useState("")
  const [more, setMore] = useState(true)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)
  const relays = scope === "following" ? uniq([...account.relays.read, ...DEFAULT_RELAYS]) : account.relays.read

  const load = async until => {
    const n = ++seq.current
    if (!follows.length) { setItems([]); return setLine("") }
    setLine(until ? "Fetching older polls…" : "Loading polls…")
    try {
      const { polls, fromNetwork } = await fetchPolls({ scope, me: ctx.session?.pubkey, follows, relays, vault, until })
      if (n !== seq.current) return
      setItems(have => (until ? [...(have ?? []), ...polls.filter(p => !have?.some(h => h.id === p.id))] : polls))
      setMore(polls.length >= PAGE / 2)
      setLine(!fromNetwork && navigator.onLine === false ? "Offline: showing saved polls" : "")
      fetchProfiles(vault, polls.map(p => p.pubkey), account.relays.read, { save: scope === "following" }).catch(() => {})
    } catch (e) { if (n === seq.current) setLine(`Couldn't load (${e?.message ?? e})`) }
  }
  useEffect(() => { setItems(null); load() }, [scope, follows.length])

  const pick = s => { savePollScope(s); setScope(s) }
  const shown = items && visibleNotes(items, blocked).filter(ev => statusAdmits(ev, status))
  return (
    <div class="reader-feed polls-feed">
      <Scopes scopes={POLL_SCOPES} value={scope} onPick={pick} onRefresh={() => load()} />
      <div class="reader-scopes"><div class="reader-scope-row" role="tablist" aria-label="Poll status">
        {POLL_STATUSES.map(s => <button key={s.id} type="button" role="tab" aria-selected={status === s.id} class={status === s.id ? "on" : ""} onClick={() => setStatus(s.id)}>{s.label}</button>)}
      </div></div>
      {line && <div class="status-line">{line}</div>}
      {!follows.length ? <p class="empty">{!account.loaded ? "Loading your follows…" : scope === "following" ? "Follow someone to see their polls here."
          : "Global shows polls from people your web of trust vouches for. Follow a few people first."}</p>
        : items === null ? <SkeletonRows count={3} label="Loading polls…" />
        : !shown.length ? <EmptyState title={emptyText(status)} detail={scope === "following" ? "Polls from people you follow show up here." : "Polls from your web of trust show up here."} />
        : <>
          {shown.map(ev => <NoteCard key={ev.id} event={ev} memoryOnly={scope !== "following"} />)}
          {more && <button class="more" onClick={() => load(items.at(-1).created_at - 1)}>Older polls</button>}
        </>}
    </div>
  )
}
