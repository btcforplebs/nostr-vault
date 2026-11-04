// Settings › Recover a List (RESEARCH/NV_LIST_MERGE_PLAN.md): the user's lists, then every version of one of them
// this browser's vault, Following Backup and the relays still hold, newest first, one summary line each. Tick
// versions, tap Merge + save: every entry of them and of the list now, each once, signed as a new version
// (list-merge-save.js) after one confirm. Per-entry ticks only behind Review. Nothing merges or saves by itself.
// Empty versions are shown, never offered.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { READ_ONLY } from "../signer/readonly.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { latestList, ListNotSaved } from "../net/list-edit.js"
import { decrypterFor, showBlockList } from "../net/blocks.js"
import { findVersions, listOverview } from "../net/list-versions.js"
import { saveMerged } from "../net/list-merge-save.js"
import { clientName, countLine, changeLine, changeTitles, mergeExplainer, saveLine, remuteLine, leftOutLines, NIP44_NOTE, needsNip44Note, entryNote } from "../net/list-version-labels.js"
import {
  MERGE_KINDS, mergeKind, openVersion, openForMerge, unread, pickProblem, deltaOf, wasWipe, buildMerge, mergedTags, mergeSummary,
} from "../net/list-version-merge.js"

const day = at => new Date(at * 1000).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
const short = at => new Date(at * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" })
const entries = n => `${n} entr${n === 1 ? "y" : "ies"}`
const SHOW = 200

/** The list the address names (`#/settings/recover-list?kind=3`, the wipe alarm's Recover), if it can be merged. */
export function kindFromHash(hash = globalThis.location?.hash ?? "") {
  const i = hash.indexOf("?")
  const k = Number(new URLSearchParams(i < 0 ? "" : hash.slice(i + 1)).get("kind"))
  return Number.isInteger(k) && mergeKind(k) ? k : null
}

export function RecoverListPage({ ctx }) {
  const [kind, setKind] = useState(kindFromHash)
  const [overview, setOverview] = useState(null)
  useEffect(() => { listOverview(ctx).then(setOverview, () => setOverview([])) }, [ctx.session.pubkey])
  if (kind) return <ListVersions ctx={ctx} kind={kind} onBack={() => setKind(null)} />
  return (
    <>
      <p class="settings-note muted small">Your vault keeps old versions of your lists. Open a list, tick the versions to
        bring back and tap Merge + save. Nothing changes until you tap Save.</p>
      <section class="settings-group">
        {MERGE_KINDS.map(({ kind: k, name }) => {
          const o = overview?.find(x => x.kind === k)
          return (
            <div key={k} class="settings-row static relay-edit-row">
              <button class="follow-backup-open" onClick={() => setKind(k)}>
                <span class="settings-title">{name}</span>
                <span class="muted small">{!overview ? "…" : o?.versions ? `${o.versions} kept by your vault · newest ${short(o.newest)}` : "None kept by your vault yet"}</span>
              </button>
            </div>
          )
        })}
      </section>
    </>
  )
}

/** One list: its versions, one summary line each, and one button that merges the ticked ones and saves (Logen
 *  2026-11-02: small, no long checklist; single entries are managed later in the normal list screens). The per-entry
 *  view is only behind "Review". */
function ListVersions({ ctx, kind, onBack }) {
  const me = ctx.session.pubkey
  const { name } = mergeKind(kind)
  const readOnly = !!ctx.signer?.readOnly
  const [load, setLoad] = useState(0)
  const [state, setState] = useState(null) // { current, checked, versions: [opened] }
  const [picked, setPicked] = useState(() => new Set())
  const [rows, setRows] = useState(null) // the merge being confirmed
  const [review, setReview] = useState(false)
  const [opening, setOpening] = useState(false)
  const [msg, setMsg] = useState("")

  useEffect(() => { (async () => {
    setState(null)
    const [latest, found, opener] = await Promise.all([
      latestList(ctx, kind).catch(() => ({ event: null, checked: false })),
      findVersions(ctx, kind),
      decrypterFor(ctx.session, { signer: ctx.signer }).catch(() => ({})),
    ])
    const evs = latest.event && !found.some(e => e.id === latest.event.id) ? [{ ...latest.event, from: ["relays"] }, ...found] : found
    const open = opener?.decrypt ? c => opener.decrypt(c) : null
    // Only the list now is decrypted here; an older version's private part is opened when it is ticked, so a NIP-07 or
    // bunker signer isn't asked once per version just to look (Tron, PR 1570).
    const versions = []
    for (const ev of evs) versions.push(await openVersion(ev, ev.id === latest.event?.id ? open : undefined))
    if (ctx.session.pubkey !== me) return
    const current = latest.event ? versions.find(v => v.ev.id === latest.event.id) : null
    setState({ current, checked: !!latest.checked, versions, open })
    setPicked(new Set()); setRows(null); setReview(false)
  })() }, [kind, load])

  if (!state) return <><Back name={name} onBack={onBack} /><p class="settings-note muted small">Looking for versions in your vault and on your relays…</p></>
  const { current, checked, versions } = state
  const others = versions.filter(v => v.ev.id !== current?.ev.id)
  // Every version, newest first, so each row can say what it changed against the one before it.
  const timeline = [...versions].sort((a, b) => b.ev.created_at - a.ev.created_at || (a.ev.id < b.ev.id ? -1 : 1))
  const olderOf = v => timeline[timeline.indexOf(v) + 1]
  const chosen = others.filter(v => picked.has(v.ev.id))
  const enough = chosen.length >= (current ? 1 : 2)
  const done = text => { setMsg(text); setLoad(n => n + 1) }
  const confirm = rows && <SaveConfirm ctx={ctx} kind={kind} name={name} current={current} rows={rows} review={review}
    onReview={() => setReview(true)} onCancel={() => { setRows(null); setReview(false) }} onSaved={done} onStale={done} />
  if (rows && review) return <MergeView ctx={ctx} kind={kind} name={name} rows={rows} setRows={setRows} onBack={() => setReview(false)}>{confirm}</MergeView>

  // Opens the versions newer than the oldest ticked one first, so what the user removed on purpose stays out.
  const merge = async () => {
    setOpening(true)
    try {
      const opened = await openForMerge(versions, chosen, state.open)
      if (ctx.session.pubkey !== me) return
      setState(st => ({ ...st, versions: opened }))
      const ids = new Set(chosen.map(v => v.ev.id))
      setRows(buildMerge({ current, picked: opened.filter(v => ids.has(v.ev.id)), all: opened }))
    } finally { setOpening(false) }
  }
  const toggle = async id => {
    setRows(null)
    const v = versions.find(x => x.ev.id === id)
    if (v?.locked && !picked.has(id)) {
      const opened = await openVersion(v.ev, state.open)
      setState(st => ({ ...st, versions: st.versions.map(x => x.ev.id === id ? opened : x) }))
      if (opened.reason) return
    }
    setPicked(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n })
  }
  return (
    <>
      <Back name={name} onBack={onBack} />
      <div class="card">
        <p class="settings-title">Merge old versions</p>
        <p class="muted small">{mergeExplainer(kind)} Tick the versions below, then tap Merge + save. Nothing changes until you tap Save.</p>
        {!current && <p class="muted small">No current {name.toLowerCase()} list of yours was found.</p>}
        {current?.reason && <p class="small">Your list now has a private part that can't be opened ({current.reason}), so it can't be merged.</p>}
        {!checked && <p class="small">Not enough of your relays answered to be sure this is your newest list. Save waits until they answer.</p>}
        {msg && <p class="small">{msg}</p>}
      </div>
      <section class="settings-group">
        {!others.length && <p class="settings-note muted small">No older version of this list was found yet. Your vault keeps one each time the list changes.</p>}
        {current && <VersionRow kind={kind} v={current} older={olderOf(current)} wipe={wasWipe(timeline, timeline.indexOf(current))} now />}
        {others.map(v => <VersionRow key={v.ev.id} kind={kind} v={v} older={olderOf(v)} wipe={wasWipe(timeline, timeline.indexOf(v))} picked={picked.has(v.ev.id)} onToggle={() => toggle(v.ev.id)} />)}
      </section>
      {readOnly ? <p class="settings-note muted small">{READ_ONLY}</p> : others.length > 0 && (rows ? confirm : (
        <div class="settings-note">
          <button class="primary" disabled={!enough || !!current?.reason || opening} onClick={merge}>{opening ? "Opening versions…" : "Merge + save"}</button>
          <p class="muted small">{current ? "Tick the versions to bring back." : "Tick two or more versions."} You can change single entries later in the list itself.</p>
        </div>
      ))}
    </>
  )
}

const Back = ({ name, onBack }) => <div class="settings-note"><button class="small" onClick={onBack}>‹ Recover a List</button> <strong>{name}</strong></div>

/** One version: the app that saved it and when, how many entries, what it changed against the one before it, and a
 *  flag when that change was a wipe. `now`: the list as it is, shown first and not tickable. */
function VersionRow({ kind, v, older, wipe, now, picked, onToggle }) {
  const problem = now ? "" : pickProblem(v)
  const count = countLine(kind, v.entries.size) + (unread(v) ? " + private" : "")
  return (
    <label class="settings-row static relay-edit-row">
      {now ? <span class="tag">Now</span>
        : <input type="checkbox" checked={picked} disabled={!!problem} onChange={onToggle} aria-label={`Merge the version from ${day(v.ev.created_at)}`} />}
      <span class="follow-backup-open">
        <span class="settings-title">{clientName(v.ev)}, {day(v.ev.created_at)}</span>
        <span class="muted small">{older ? `${count}, ${changeLine(deltaOf(v, older))}` : count}</span>
        {wipe && <span class="small list-wipe-flag">This one wiped your list</span>}
        {(problem || v.locked) && <span class="muted small">{problem || "Private part opens when you tick it"}</span>}
      </span>
    </label>
  )
}

/** What Save does, in one or two lines, and Save. Shared by the quick path and Review. */
function SaveConfirm({ ctx, kind, name, current, rows, review, onReview, onCancel, onSaved, onStale }) {
  const [shrinkOk, setShrinkOk] = useState(false)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState("")
  const sum = mergeSummary(kind, rows)
  const titles = changeTitles(kind)
  const backRows = rows.filter(r => r.status !== "current" && r.ticked)
  const goneRows = rows.filter(r => r.status === "current" && !r.ticked)
  useEffect(() => { fetchPeople(ctx, rows) }, [rows])
  useEffect(() => setShrinkOk(false), [sum.removed])
  const save = async () => {
    setBusy(true); setMsg("")
    try {
      const { tags, privateTags } = mergedTags(rows, current)
      const { event, took, of } = await saveMerged(ctx, kind, { base: current?.ev ?? null, baseOpened: !!current && !unread(current), tags, privateTags })
      await ctx.reloadAccount?.().catch(() => {})
      if (kind === 10000) await showBlockList(ctx, event).catch(() => {})
      onSaved(`Saved: your ${name.toLowerCase()} now has ${entries(sum.total)}, taken by ${took} of your ${of} relays. The list you had stays in your vault's history.`)
    } catch (e) {
      if (e instanceof ListNotSaved && e.checked) onStale(e.message)
      else setMsg(String(e?.message ?? e))
    } finally { setBusy(false) }
  }
  const nothing = !sum.added && !sum.removed
  return (
    <div class="card">
      <p class="small">{saveLine(kind, name, sum)}</p>
      <PeoplePeek title={titles.back} rows={backRows} />
      <PeoplePeek title={titles.gone} rows={goneRows} />
      {leftOutLines(sum, { box: !!ctx.vault?.box }).map(line => <p key={line} class="muted small">{line}</p>)}
      {remuteLine(sum.remutes) && <p class="small">{remuteLine(sum.remutes)}</p>}
      {needsNip44Note(kind, current?.ev.content, rows) && <p class="muted small">{NIP44_NOTE}</p>}
      {sum.removed > 0 && <label class="small"><input type="checkbox" checked={shrinkOk} onChange={e => setShrinkOk(e.currentTarget.checked)} /> {kind === 3 ? `Yes, unfollow ${sum.removed}.` : `Yes, take ${entries(sum.removed)} out of the list I have now.`}</label>}
      <div class="row">
        <button class="primary" disabled={busy || nothing || !sum.total || (sum.removed > 0 && !shrinkOk)} onClick={save} aria-busy={busy || undefined}>{busy ? "Saving…" : "Save"}</button>
        <button disabled={busy} onClick={onCancel}>Cancel</button>
        {!review && (!nothing || sum.leftOut + sum.unsure > 0) && <button class="small link" disabled={busy} onClick={onReview}>Review</button>}
      </div>
      {msg && <p class="muted small">{msg}</p>}
    </div>
  )
}

/** Review: the merged entries, each with a tick. Only behind the Review link. */
function MergeView({ ctx, kind, name, rows, setRows, onBack, children }) {
  const titles = changeTitles(kind)
  const [showAll, setShowAll] = useState({})
  const back = rows.filter(r => r.status !== "current"), now = rows.filter(r => r.status === "current")
  const tick = key => setRows(rs => rs.map(r => r.key === key ? { ...r, ticked: !r.ticked } : r))
  const section = (label, list, id, note) => list.length > 0 && (
    <section class="settings-group">
      <div class="section-label">{label} ({list.length})</div>
      {(showAll[id] ? list : list.slice(0, SHOW)).map(r => <EntryRow key={r.key} row={r} box={!!ctx.vault?.box} onTick={() => tick(r.key)} />)}
      {list.length > SHOW && !showAll[id] && <div class="settings-note"><button class="small" onClick={() => setShowAll(s => ({ ...s, [id]: true }))}>Show all {list.length}</button></div>}
      <p class="settings-note muted small">{note}</p>
    </section>
  )
  return (
    <>
      <div class="settings-note"><button class="small" onClick={onBack}>‹ {name} versions</button></div>
      {children}
      {section(titles.back, back, "back", "Ones dropped in an ordinary edit, or that can't be judged, are left unticked; tick them to bring them back.")}
      {section(titles.kept, now, "now", kind === 3 ? "Untick someone to unfollow them." : "Untick an entry to take it out.")}
    </>
  )
}

function EntryRow({ row, box, onTick }) {
  const [t0, v] = row.tag
  const label = entryNote(row, short, { box })
  return (
    <label class="person-row">
      <input type="checkbox" checked={row.ticked} onChange={onTick} aria-label={`Keep ${v}`} />
      {t0 === "p" ? <><Avatar pubkey={v} size={30} /><span class="person-names"><a href={`#/profile/${v}`}><AuthorName pubkey={v} /></a></span></>
        : <span class="person-names">{entryText(row.tag)}</span>}
      {row.private && <span class="tag">Private</span>}
      {label && <span class="muted small">{label}</span>}
    </label>
  )
}

/** Pictures and names for the people in a merge, so no one shows as a key. */
function fetchPeople(ctx, rows) {
  const pks = rows.filter(r => r.tag[0] === "p").map(r => r.tag[1]).slice(0, 300)
  if (pks.length) fetchProfiles(ctx.vault, pks, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
}

const PEEK = 8
/** The first few entries of one side of a merge, as picture + name (people) or text, and how many more. */
function PeoplePeek({ title, rows }) {
  if (!rows.length) return null
  return (
    <div class="merge-peek">
      <div class="section-label">{title} ({rows.length.toLocaleString("en-US")})</div>
      <div class="merge-peek-list">
        {rows.slice(0, PEEK).map(r => r.tag[0] === "p"
          ? <span key={r.key} class="merge-peek-person"><Avatar pubkey={r.tag[1]} size={22} /><AuthorName pubkey={r.tag[1]} /></span>
          : <span key={r.key} class="merge-peek-person">{entryText(r.tag)}</span>)}
        {rows.length > PEEK && <span class="muted small">and {(rows.length - PEEK).toLocaleString("en-US")} more</span>}
      </div>
    </div>
  )
}

/** One entry that isn't a person, as text. */
function entryText(tag) {
  const [t0, v] = tag
  if (t0 === "e") return <a href={`#/thread/${v}`}>Note {v.slice(0, 12)}…</a>
  if (t0 === "t") return `#${v}`
  if (t0 === "word") return `“${v}”`
  if (t0 === "emoji") return `:${v}:`
  return v
}

