// Settings › Media Servers (iPhone BlossomSettingsView, "Other Servers"): the account's Blossom servers (BUD-03,
// kind 10063), where Compose uploads photos, with Remove and Add. Saving signs and publishes the new list. Each saved
// server is tested as the page opens, as the phone's MediaServersPage does. Mesh vault entries (fipsmesh://) aren't
// tested or shown with them: they get their own rows (MeshVaultRows.jsx). As on iPhone/Mac and Android, every add and
// remove only changes the list on screen; Save publishes it once, and leaving with unsaved changes asks Save or Discard.
import { useEffect, useRef, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { serverUrl, DEFAULT_MEDIA_SERVERS } from "../net/upload.js"
import { testServer, SERVER_STATES } from "../net/blossom-gallery.js"
import { latestList, publishList, ListNotSaved, NO_RELAY_LIST, serverEntries, serverTags, addServer, removeServer, serverProblem, sameRows, isMeshServer } from "../net/list-edit.js"
import { SkeletonList } from "../components/Loading.jsx"
import { MeshPhotosSwitch } from "../components/MeshPhotosSwitch.jsx"
import { SuggestedServers } from "../components/SuggestedServers.jsx"
import { MeshVaultRows } from "./MeshVaultRows.jsx"
import { Dialog } from "../components/Moderation.jsx"
import { guardLeave } from "../net/leave-guard.js"
import { changeCount, saveLabel, ONLY_SAVE, leaveQuestion, LEAVE_NOTE } from "../net/media-servers-draft.js"

const loopback = url => { try { return /^(localhost|127\.|\[::1\])/.test(new URL(url).hostname) } catch { return false } }

export function MediaServersPage({ ctx }) {
  const readOnly = !!ctx.signer?.readOnly
  const [loaded, setLoaded] = useState(null) // { event, checked }
  const [urls, setUrls] = useState([])
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")
  const [health, setHealth] = useState({}) // url -> "checking" | { state, reason, at }
  const test = async url => {
    setHealth(h => ({ ...h, [url]: "checking" }))
    const r = await testServer(url, ctx.session.pubkey, { ctx }).catch(e => ({ state: "offline", reason: String(e?.message ?? e) }))
    setHealth(h => ({ ...h, [url]: { ...r, at: Date.now() } }))
  }

  // An edit starts from the account's own list. Only when the relays answered that it has none does it start from the
  // defaults (what it uploads to meanwhile); a list nobody could read starts empty, so the defaults are never saved
  // over a list that exists.
  const start = r => r?.event ? serverEntries(r.event) : r?.checked ? DEFAULT_MEDIA_SERVERS : []
  useEffect(() => {
    latestList(ctx, 10063).then(r => { setLoaded(r); setUrls(start(r)); start(r).filter(u => !isMeshServer(u)).forEach(test) }).catch(e => { setLoaded({ event: undefined, checked: false }); setUrls([]); setErr(String(e?.message ?? e)) })
  }, [])

  const saved = start(loaded)
  const dirty = !!loaded && !sameRows(urls, saved)
  const problem = serverProblem(urls)
  const servers = urls.filter(u => !isMeshServer(u))
  const changes = dirty ? changeCount(urls, saved) : 0
  const canSave = dirty && !busy && !problem && !!loaded?.checked

  // Leaving with unsaved changes asks first (‹ Settings, the rail, the browser's Back): `leaving` is where to.
  const [leaving, setLeaving] = useState(null)
  const dirtyNow = useRef(false)
  dirtyNow.current = dirty
  const guard = useRef(null)
  useEffect(() => {
    guard.current = guardLeave(globalThis, { isDirty: () => dirtyNow.current, ask: setLeaving })
    return () => guard.current.stop()
  }, [])

  const add = e => {
    e.preventDefault()
    const url = serverUrl(/^https?:\/\//i.test(typed.trim()) ? typed : `https://${typed.trim()}`)
    if (!url || loopback(url)) { setErr(url ? "That's this computer's own address. Nobody else can reach it, so it can't go in your public list." : "That isn't a media server address. Type one like blossom.example.com or https://blossom.example.com."); return }
    setUrls(addServer(urls, url)); setTyped(""); setErr(""); setStatus("")
  }
  const save = async () => {
    setBusy(true); setErr(""); setStatus("")
    try {
      const { event, relays } = await publishList(ctx, 10063, serverTags(urls, loaded.event), { previous: loaded.event })
      setLoaded({ event, checked: true }); setUrls(serverEntries(event))
      setStatus(`Published to ${relays.filter(r => r.ok).length} of ${relays.length} relays. New photos go to ${serverEntries(event).find(u => !isMeshServer(u))} first.`)
      dirtyNow.current = false
      return true
    } catch (e) {
      if (e instanceof ListNotSaved && e.checked) { const r = { event: e.latest, checked: true }; setLoaded(r); setUrls(start(r)) }
      setErr(String(e?.message ?? e))
      return false
    } finally { setBusy(false) }
  }

  if (!loaded) return <SkeletonList count={4} rowClass="settings-row static" avatar={0} lines={1} label="Loading your media servers…" />
  return (
    <>
      <p class="settings-note muted small">Photos you attach to a note are uploaded here, the first server first. Other apps read this list to find your files.</p>
      {!loaded.checked && loaded.noRelayList && <p class="settings-note small error">{NO_RELAY_LIST}</p>}
      {!loaded.checked && !loaded.noRelayList && <p class="settings-note small error">Your relays couldn't be checked, so this may not be your newest list. Go online before you change it.</p>}
      {!loaded.event && loaded.checked && <p class="settings-note muted small">You haven't published a list, so the defaults below are used. Saving publishes them with your changes.</p>}
      {servers.map((url, i) => (
        <div key={url} class="settings-row static relay-edit-row">
          <span class="settings-title mono" title={url}>{url}<Health h={health[url]} /></span>
          <span class="settings-tags">
            {i === 0 && <span class="tag">first</span>}
            {!loaded.event && loaded.checked && DEFAULT_MEDIA_SERVERS.includes(url) && <span class="tag">default</span>}
            {serverUrl(url) === null && <span class="tag">not used</span>}
            {saved.includes(url) && <button type="button" class="small relay-remove" disabled={health[url] === "checking"} aria-label={`Test ${url}`} onClick={() => test(url)}>{health[url] === "checking" ? "Testing…" : "Test"}</button>}
            {!readOnly && <button type="button" class="small relay-remove" disabled={busy} aria-label={`Remove ${url}`} onClick={() => setUrls(removeServer(urls, url))}>Remove</button>}
          </span>
        </div>
      ))}
      <MeshVaultRows urls={urls} readOnly={readOnly} busy={busy} onRemove={url => { setUrls(removeServer(urls, url)); setErr(""); setStatus("") }} />
      {readOnly ? <p class="settings-note muted small">{READ_ONLY}</p> : (
        <>
          <form class="settings-row static relay-add" onSubmit={add}>
            <input type="text" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck={false} placeholder="https://blossom.example.com" aria-label="Media server address" value={typed} onInput={e => setTyped(e.currentTarget.value)} disabled={busy} />
            <button type="submit" class="small" disabled={busy || !typed.trim()}>Add</button>
          </form>
          <SuggestedServers urls={urls} disabled={busy} onAdd={url => { setUrls(addServer(urls, url)); setErr(""); setStatus("") }} />
          <div class="settings-note row">
            <button class="primary" disabled={!canSave} onClick={save} aria-busy={busy || undefined}>{busy ? "Publishing…" : saveLabel(changes)}</button>
            {dirty && <button disabled={busy} onClick={() => { setUrls(saved); setErr("") }}>Discard changes</button>}
          </div>
          <p class="settings-note muted small">{ONLY_SAVE}</p>
          {dirty && problem && <p class="settings-note small error">{problem}</p>}
        </>
      )}
      {leaving && (
        <Dialog label={leaveQuestion(changes || 1)} onClose={() => setLeaving(null)}>
          <h3>{leaveQuestion(changes || 1)}</h3>
          <p class="muted small">{LEAVE_NOTE}</p>
          {!canSave && problem && <p class="small error">{problem}</p>}
          <div class="mod-row media-servers-leave">
            <button type="button" class="primary" disabled={!canSave} onClick={async () => { const to = leaving; setLeaving(null); if (await save()) guard.current.leave(to) }}>Save</button>
            <button type="button" class="danger" onClick={() => { const to = leaving; dirtyNow.current = false; setLeaving(null); guard.current.leave(to) }}>Discard</button>
            <button type="button" autofocus onClick={() => setLeaving(null)}>Keep Editing</button>
          </div>
        </Dialog>
      )}
      {status && <p class="settings-note muted small">{status}</p>}
      {err && <p class="settings-note small error">{err}</p>}
      <MeshPhotosSwitch />
    </>
  )
}

/** A tested server's line: a dot and the phone's words, with why when it isn't working. */
function Health({ h }) {
  if (!h || h === "checking") return <span class="server-health muted">{h ? "Checking…" : "Not checked yet"}</span>
  return <span class={`server-health ${h.state}`}><span class="dot" />{SERVER_STATES[h.state]}{h.reason && h.state !== "working" ? ` (${h.reason})` : ""} · checked {checkedAgo(h.at)}</span>
}

/** "just now" under a minute, then "5 minutes ago" (the phone's .relative(presentation: .named)). */
export function checkedAgo(at, now = Date.now(), locale) {
  const s = (now - at) / 1000
  if (s < 60) return "just now"
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" })
  return s < 3600 ? rtf.format(-Math.floor(s / 60), "minute") : rtf.format(-Math.floor(s / 3600), "hour")
}
