// Settings › Relays (iPhone RelayMatrixView, Read and Write columns): the account's relay list (NIP-65, kind 10002)
// with read and write switches per relay, Remove, and Add. Saving signs and publishes the new list. The list draws
// from Haven's copy or the first relay to answer; editing waits until every relay has been asked (`pending`).
import { useEffect, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { isDead } from "../net/pool.js"
import { RelayUrlList } from "./RelayUrlList.jsx"
import { latestList, publishList, ListNotSaved, relayUrl, relayUrlError, relayEntries, addRelay, setJob, removeRelay, relayTags, relayProblem, sameRows } from "../net/list-edit.js"
import { SkeletonList } from "../components/Loading.jsx"

export function RelaysPage({ ctx }) {
  const readOnly = !!ctx.signer?.readOnly
  const [loaded, setLoaded] = useState(null) // { event, checked, pending }
  const [rows, setRows] = useState([])
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")

  const early = ({ event }) => { setLoaded({ event, checked: false, pending: true }); setRows(relayEntries(event)) }
  const load = () => latestList(ctx, 10002, { on: early }).then(r => { setLoaded(r); setRows(relayEntries(r.event)) }).catch(e => { setLoaded({ event: undefined, checked: false }); setErr(String(e?.message ?? e)) })
  useEffect(() => { load() }, [])

  const saved = relayEntries(loaded?.event)
  const dirty = !sameRows(rows, saved)
  const problem = relayProblem(rows)
  const locked = readOnly || busy || !!loaded?.pending

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
    } catch (e) {
      if (e instanceof ListNotSaved && e.checked) { setLoaded({ event: e.latest, checked: true }); setRows(relayEntries(e.latest)) }
      setErr(String(e?.message ?? e))
    } finally { setBusy(false) }
  }

  return (
    <>
      {!loaded ? <SkeletonList count={4} rowClass="settings-row static" avatar={0} lines={1} label="Loading your relays…" /> : <>
      {loaded.pending && <p class="settings-note muted small" role="status">Checking your relays for a newer list…</p>}
      {!loaded.checked && !loaded.pending && <p class="settings-note small error">Your relays couldn't be checked, so this may not be your newest list. Go online before you change it.</p>}
      {!loaded.event && loaded.checked && <p class="settings-note muted small">No relays yet. Add one below.</p>}
      {rows.map(r => (
        <div key={r.url} class="settings-row static relay-edit-row">
          <span class="settings-title mono" title={r.url}>{host(r.url)}{isDead(r.url) && <span class="tag">not answering</span>}</span>
          <span class="settings-tags">
            <Job on={r.read} label="Read" disabled={locked} onClick={() => setRows(setJob(rows, r.url, "read", !r.read))} />
            <Job on={r.write} label="Write" disabled={locked} onClick={() => setRows(setJob(rows, r.url, "write", !r.write))} />
            {!readOnly && <button type="button" class="small relay-remove" disabled={locked} aria-label={`Remove ${r.url}`} onClick={() => setRows(removeRelay(rows, r.url))}>Remove</button>}
          </span>
        </div>
      ))}
      <p class="settings-note muted small">Read + Write are your public relay list (10002). Your phone and other apps use the same list.</p>
      {readOnly ? <p class="settings-note muted small">{READ_ONLY}</p> : (
        <>
          <form class="settings-row static relay-add" onSubmit={add}>
            <input type="text" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck={false} placeholder="relay.example.com" aria-label="Relay address" value={typed} onInput={e => setTyped(e.currentTarget.value)} disabled={locked} />
            <button type="submit" class="small" disabled={locked || !typed.trim()}>Add</button>
          </form>
          {dirty && (
            <div class="settings-note row">
              <button class="primary" disabled={busy || !!problem || !loaded.checked} onClick={save} aria-busy={busy || undefined}>{busy ? "Publishing…" : "Save and publish"}</button>
              <button disabled={busy} onClick={() => { setRows(saved); setErr("") }}>Discard changes</button>
            </div>
          )}
          {dirty && problem && <p class="settings-note small error">{problem}</p>}
        </>
      )}
      {status && <p class="settings-note muted small">{status}</p>}
      {err && <p class="settings-note small error">{err}</p>}
      </>}
      <RelayUrlList ctx={ctx} kind={10050} title="DMs" needsOne
        note="Your DM inbox (10050): where people send you private messages. Messages here read from these relays too."
        empty="No messages list of yours was found, so people send to your Read relays." />
      <RelayUrlList ctx={ctx} kind={10006} title="Never Connect" removeLabel="Unblock"
        note="The app won't open a connection to these, even when someone you follow uses them (your bunker's own relay excepted). Published as your blocked relay list (10006)."
        empty="No relays are on your never-connect list." />
    </>
  )
}

/** The phone shows a relay by its host (RelayMatrix's label): the address without wss://. */
const host = url => url.replace(/^wss:\/\//, "")

const Job = ({ on, label, disabled, onClick }) => (
  <button type="button" class={`tag job ${on ? "on" : ""}`} aria-pressed={on} disabled={disabled} title={on ? `Stop using it to ${label.toLowerCase()}` : `Use it to ${label.toLowerCase()}`} onClick={onClick}>{label}</button>
)
