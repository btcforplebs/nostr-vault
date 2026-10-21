// Settings › Following Backup (iPhone FollowingBackupView): your follow list now, the copies this browser kept of it,
// older lists your relays still hold, and for each one who you no longer follow (Re-follow) and who you added since.
// Restore puts an old list back as your follow list, after asking.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { READ_ONLY } from "../signer/readonly.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { followsOf, setFollow, findLatestList } from "../net/follows.js"
import { snapshotStore, keepSnapshot, scanRelays, diffLists, restoreBase, restoreList } from "../net/follow-backup.js"

const day = at => new Date(at * 1000).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
const follows = n => `${n} follow${n === 1 ? "" : "s"}`

export function FollowingBackupPage({ ctx }) {
  const me = ctx.session.pubkey
  const relays = uniq([...ctx.account.relays.read, ...ctx.account.relays.write])
  const [store] = useState(() => snapshotStore(me))
  const [current, setCurrent] = useState(undefined) // the newest kind 3, null when none
  const [snaps, setSnaps] = useState([])
  const [found, setFound] = useState(null) // relay scan results
  const [scanning, setScanning] = useState(false)
  const [open, setOpen] = useState(null) // the list opened
  const [err, setErr] = useState("")
  const [note, setNote] = useState("")

  const reload = async () => setSnaps(await store.all().catch(() => []))
  useEffect(() => { (async () => {
    const { base } = await findLatestList({ vault: ctx.vault, pubkey: me, relays, known: ctx.account.contacts }).catch(() => ({ base: ctx.account.contacts }))
    setCurrent(base ?? null)
    if (base) await keepSnapshot(store, base, me).catch(() => {})
    await reload()
  })() }, [me])

  const scan = async () => {
    setScanning(true); setErr("")
    try { setFound(await scanRelays(me, [...relays, ...DEFAULT_RELAYS])) } catch (e) { setErr(String(e?.message ?? e)) } finally { setScanning(false) }
  }

  if (open) return <ListDetail ctx={ctx} list={open} current={current} store={store} onBack={() => setOpen(null)} onRestored={(ev, msg) => { setCurrent(ev); setOpen(null); setNote(msg); keepSnapshot(store, ev, me).catch(() => {}).then(reload) }} />
  return (
    <>
      <p class="settings-note muted small">Your follow list is one event your apps replace on every follow. If one of them loses it, an older copy brings your follows back.</p>
      <div class="card">
        <h3>Your follow list now</h3>
        {note && <p class="small">{note}</p>}
        <p class="muted small">{current === undefined ? "Checking your relays…" : current ? `${follows(followsOf(current).length)}, from ${day(current.created_at)}.` : "No follow list of yours was found."}</p>
      </div>
      <section class="settings-group">
        <div class="section-label">Recover Following List</div>
        {found ? (found.length ? found.map(l => <ListRow key={l.id} list={l} current={current} onOpen={() => setOpen(l)} />) : <p class="settings-note muted small">Your relays hold no follow list of yours.</p>)
          : !scanning && <p class="settings-note muted small">Tap "Scan Relays" to search for historical contact lists.</p>}
        <div class="settings-note"><button disabled={scanning} onClick={scan}>{scanning ? "Asking your relays…" : found ? "Rescan Relays" : "Scan Relays"}</button></div>
        {err && <p class="settings-note small error">{err}</p>}
      </section>
      {snaps.length > 0 && (
        <section class="settings-group">
          <div class="section-label">Automatic Backups</div>
          {snaps.map(s => <ListRow key={s.id} list={s} current={current} onOpen={() => setOpen(s)} onDelete={async () => { await store.remove(s.id); reload() }} />)}
          <p class="settings-note muted small">Snapshots are saved automatically when your following list changes. Up to 50 are kept.</p>
        </section>
      )}
    </>
  )
}

function ListRow({ list, current, onOpen, onDelete }) {
  const n = followsOf(list).length
  const isNow = current && list.id === current.id
  return (
    <div class="settings-row static relay-edit-row">
      <button class="follow-backup-open" onClick={onOpen}>
        <span class="settings-title">{day(list.created_at)}</span>
        <span class="muted small">{n} following{isNow ? " · Current" : ""}</span>
      </button>
      {onDelete && <button class="small relay-remove" aria-label="Delete this copy" onClick={onDelete}>Delete</button>}
    </div>
  )
}

/** One list: what changed since, Re-follow per person, and Restore. (iPhone SnapshotDetailView / Kind3EventDetailView) */
function ListDetail({ ctx, list, current, store, onBack, onRestored }) {
  const readOnly = !!ctx.signer?.readOnly
  const [refollowed, setRefollowed] = useState(() => new Set())
  const [busy, setBusy] = useState("")
  const [asking, setAsking] = useState(false)
  const [shown, setShown] = useState(null) // the newest list, asked for again before Restore: the confirm and diff are against it
  const now = asking && shown ? shown : current
  const { removed, added } = diffLists(now, list)
  const [msg, setMsg] = useState("")
  const isNow = current && list.id === current.id
  useEffect(() => { const pks = [...removed, ...added].slice(0, 200); if (pks.length) fetchProfiles(ctx.vault, pks, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])).catch(() => {}) }, [list.id])

  const refollow = async pk => {
    setBusy(pk); setMsg("")
    try {
      await setFollow({ vault: ctx.vault, signer: ctx.signer, pubkey: ctx.session.pubkey, target: pk, follow: true, readRelays: ctx.account.relays.read, writeRelays: ctx.account.relays.write, known: current, appCount: followsOf(current).length })
      setRefollowed(s => new Set([...s, pk]))
    } catch (e) { setMsg(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const ask = async () => {
    setBusy("check"); setMsg("")
    try { setShown(await restoreBase({ ctx })); setAsking(true) } catch (e) { setMsg(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const restore = async () => {
    setBusy("restore"); setMsg("")
    try {
      const { event, relays } = await restoreList({ ctx, old: list, shown, store })
      // The rest of the app follows from ctx.account: left on the old list, its next follow would be refused.
      await ctx.reloadAccount().catch(() => {})
      onRestored(event, `Restored: ${follows(followsOf(event).length)}, sent to ${relays.filter(r => r.ok).length} of ${relays.length} relays.`)
    } catch (e) { setMsg(String(e?.message ?? e)) } finally { setBusy(""); setAsking(false) }
  }

  return (
    <>
      <div class="settings-note"><button class="small" onClick={onBack}>‹ Following Backup</button></div>
      <div class="card">
        <h3>{day(list.created_at)}</h3>
        <p class="muted small">{follows(followsOf(list).length)}{isNow ? ", your follow list now" : ` · you follow ${followsOf(now).length} now`}.</p>
        {!isNow && !readOnly && (asking
          ? <>
              <p class="small">This will replace your current {follows(followsOf(shown).length)} with {follows(followsOf(list).length)} from this backup and publish the updated list to your relays. Your current list is kept here first.</p>
              <div class="row"><button class="danger" disabled={!!busy} onClick={restore} aria-busy={busy === "restore" || undefined}>{busy === "restore" ? "Restoring…" : "Restore"}</button><button disabled={!!busy} onClick={() => setAsking(false)}>Cancel</button></div>
            </>
          : <button class="primary" disabled={!!busy} onClick={ask} aria-busy={busy === "check" || undefined}>{busy === "check" ? "Checking your relays…" : "Restore This List"}</button>)}
        {readOnly && <p class="muted small">{READ_ONLY}</p>}
        {msg && <p class="muted small">{msg}</p>}
      </div>
      {!isNow && removed.length > 0 && (
        <section class="settings-group">
          <div class="section-label">No Longer Following ({removed.length})</div>
          {removed.map(pk => (
            <div key={pk} class="person-row">
              <Avatar pubkey={pk} size={34} />
              <span class="person-names"><a href={`#/profile/${pk}`}><AuthorName pubkey={pk} /></a></span>
              {refollowed.has(pk) ? <span class="tag">✓</span>
                : !readOnly && <button class="small" disabled={!!busy} onClick={() => refollow(pk)} aria-busy={busy === pk || undefined}>{busy === pk ? "Following…" : "Re-follow"}</button>}
            </div>
          ))}
          <p class="settings-note muted small">People in this backup that you no longer follow.</p>
        </section>
      )}
      {!isNow && added.length > 0 && (
        <section class="settings-group">
          <div class="section-label">Added Since ({added.length})</div>
          {added.map(pk => <div key={pk} class="person-row"><Avatar pubkey={pk} size={34} /><span class="person-names"><a href={`#/profile/${pk}`}><AuthorName pubkey={pk} /></a></span><span class="tag">New</span></div>)}
          <p class="settings-note muted small">People you follow now that were not in this backup.</p>
        </section>
      )}
    </>
  )
}
