// Settings › Relays (iPhone RelayMatrixView, Read and Write columns): the account's relay list (NIP-65, kind 10002)
// with read and write switches per relay, Remove, and Add. Saving signs and publishes the new list.
import { useEffect, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { isDead } from "../net/pool.js"
import { latestList, publishList, relayUrl, relayUrlError, relayEntries, addRelay, setJob, removeRelay, relayTags, relayProblem, sameRows } from "../net/list-edit.js"

export function RelaysPage({ ctx }) {
  const readOnly = !!ctx.signer?.readOnly
  const [loaded, setLoaded] = useState(null) // { event, checked }
  const [rows, setRows] = useState([])
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")

  const load = () => latestList(ctx, 10002).then(r => { setLoaded(r); setRows(relayEntries(r.event)) }).catch(e => { setLoaded({ event: undefined, checked: false }); setErr(String(e?.message ?? e)) })
  useEffect(() => { load() }, [])

  const saved = relayEntries(loaded?.event)
  const dirty = !sameRows(rows, saved)
  const problem = relayProblem(rows)

  const add = e => {
    e.preventDefault()
    const url = relayUrl(typed)
    if (!url) { setErr(relayUrlError(typed)); return }
    setRows(addRelay(rows, url)); setTyped(""); setErr(""); setStatus("")
  }
  const save = async () => {
    setBusy(true); setErr(""); setStatus("")
    try {
      const { event, relays } = await publishList(ctx, 10002, relayTags(rows, loaded.event), { previous: loaded.event, also: rows.filter(r => r.write).map(r => r.url) })
      setLoaded({ event, checked: true }); setRows(relayEntries(event))
      setStatus(`Published to ${relays.filter(r => r.ok).length} of ${relays.length} relays. Reload to use the new list here.`)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  if (!loaded) return <p class="empty">Loading…</p>
  return (
    <>
      <p class="settings-note muted small">Where your notes are published (Write) and where people find them (Read), as your relay list (NIP-65) says. Your phone and other apps use the same list.</p>
      {!loaded.checked && <p class="settings-note small error">Your relays couldn't be checked, so this may not be your newest list. Go online before you change it.</p>}
      {!loaded.event && loaded.checked && <p class="settings-note muted small">No relay list of yours was found. Saving publishes your first one.</p>}
      {rows.map(r => (
        <div key={r.url} class="settings-row static relay-edit-row">
          <span class="settings-title mono" title={r.url}>{r.url}{isDead(r.url) && <span class="tag">not answering</span>}</span>
          <span class="settings-tags">
            <Job on={r.read} label="read" disabled={readOnly || busy} onClick={() => setRows(setJob(rows, r.url, "read", !r.read))} />
            <Job on={r.write} label="write" disabled={readOnly || busy} onClick={() => setRows(setJob(rows, r.url, "write", !r.write))} />
            {!readOnly && <button type="button" class="small relay-remove" disabled={busy} aria-label={`Remove ${r.url}`} onClick={() => setRows(removeRelay(rows, r.url))}>Remove</button>}
          </span>
        </div>
      ))}
      {readOnly ? <p class="settings-note muted small">{READ_ONLY}</p> : (
        <>
          <form class="settings-row static relay-add" onSubmit={add}>
            <input type="text" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck={false} placeholder="relay.example.com" aria-label="Relay address" value={typed} onInput={e => setTyped(e.currentTarget.value)} disabled={busy} />
            <button type="submit" class="small" disabled={busy || !typed.trim()}>Add</button>
          </form>
          {dirty && (
            <div class="settings-note row">
              <button class="primary" disabled={busy || !!problem || !loaded.checked} onClick={save}>{busy ? "Publishing…" : "Save and publish"}</button>
              <button disabled={busy} onClick={() => { setRows(saved); setErr("") }}>Discard changes</button>
            </div>
          )}
          {dirty && problem && <p class="settings-note small error">{problem}</p>}
        </>
      )}
      {status && <p class="settings-note muted small">{status}</p>}
      {err && <p class="settings-note small error">{err}</p>}
    </>
  )
}

const Job = ({ on, label, disabled, onClick }) => (
  <button type="button" class={`tag job ${on ? "on" : ""}`} aria-pressed={on} disabled={disabled} title={on ? `Stop using it to ${label}` : `Use it to ${label}`} onClick={onClick}>{label}</button>
)
