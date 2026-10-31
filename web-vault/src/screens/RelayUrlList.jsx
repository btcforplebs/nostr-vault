// One plain relay list under Settings › Relays (iPhone RelayMatrixView's DMs column and its Never Connect list): the
// list's relays with Remove, an Add field, and Save and publish. `kind` 10050 is where people send you messages
// (NIP-17); 10006 is the relays your apps should never connect to (NIP-51). Draws early and locks editing until every
// relay has been asked, as RelaysPage.
import { useEffect, useState } from "preact/hooks"
import { latestList, publishList, ListNotSaved, relayUrl, relayUrlError, urlEntries, urlTags, addUrl, removeUrl, sameRows } from "../net/list-edit.js"
import { SkeletonList } from "../components/Loading.jsx"

export function RelayUrlList({ ctx, kind, title, note, empty, needsOne = false, removeLabel = "Remove" }) {
  const readOnly = !!ctx.signer?.readOnly
  const [loaded, setLoaded] = useState(null) // { event, checked, pending }
  const [urls, setUrls] = useState([])
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")
  useEffect(() => {
    latestList(ctx, kind, { on: ({ event }) => { setLoaded({ event, checked: false, pending: true }); setUrls(urlEntries(event)) } }).then(r => { setLoaded(r); setUrls(urlEntries(r.event)) }).catch(e => { setLoaded({ event: undefined, checked: false }); setErr(String(e?.message ?? e)) })
  }, [kind])

  const saved = urlEntries(loaded?.event)
  const dirty = !!loaded && !sameRows(urls, saved)
  const locked = busy || !!loaded?.pending
  const problem = needsOne && !urls.length ? "Keep at least one relay, or nobody knows where to send your messages." : ""
  const add = e => {
    e.preventDefault()
    const url = relayUrl(typed)
    if (!url) { setErr(relayUrlError(typed)); return }
    setUrls(addUrl(urls, url)); setTyped(""); setErr(""); setStatus("")
  }
  const save = async () => {
    setBusy(true); setErr(""); setStatus("")
    try {
      const { event, relays } = await publishList(ctx, kind, urlTags(urls, loaded.event), { previous: loaded.event })
      setLoaded({ event, checked: true }); setUrls(urlEntries(event))
      setStatus(`Published to ${relays.filter(r => r.ok).length} of ${relays.length} relays.`)
      if (kind === 10006) ctx.reloadAccount?.().catch(() => {}) // the pool takes the new Never Connect list now
    } catch (e) {
      if (e instanceof ListNotSaved && e.checked) { setLoaded({ event: e.latest, checked: true }); setUrls(urlEntries(e.latest)) }
      setErr(String(e?.message ?? e))
    } finally { setBusy(false) }
  }

  return (
    <section class="settings-group relay-list">
      <div class="section-label">{title}</div>
      <p class="settings-note muted small">{note}</p>
      {!loaded ? <SkeletonList count={4} rowClass="settings-row static" avatar={0} lines={1} label="Loading your list…" /> : <>
        {loaded.pending && <p class="settings-note muted small" role="status">Checking your relays for a newer list…</p>}
        {!loaded.checked && !loaded.pending && <p class="settings-note small error">Your relays couldn't be checked, so this may not be your newest list.</p>}
        {!urls.length && <p class="settings-note muted small">{empty}</p>}
        {urls.map(u => (
          <div key={u} class="settings-row static relay-edit-row">
            <span class="settings-title mono" title={u}>{u.replace(/^wss:\/\//, "")}</span>
            {!readOnly && <span class="settings-tags"><button type="button" class="small relay-remove" disabled={locked} aria-label={`${removeLabel} ${u}`} onClick={() => setUrls(removeUrl(urls, u))}>{removeLabel}</button></span>}
          </div>
        ))}
        {!readOnly && <>
          <form class="settings-row static relay-add" onSubmit={add}>
            <input type="text" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck={false} placeholder="relay.example.com" aria-label={`Add to ${title}`} value={typed} onInput={e => setTyped(e.currentTarget.value)} disabled={locked} />
            <button type="submit" class="small" disabled={locked || !typed.trim()}>Add</button>
          </form>
          {dirty && (
            <div class="settings-note row">
              <button class="primary" disabled={busy || !!problem || !loaded.checked} onClick={save} aria-busy={busy || undefined}>{busy ? "Publishing…" : "Save and publish"}</button>
              <button disabled={busy} onClick={() => { setUrls(saved); setErr("") }}>Discard changes</button>
            </div>
          )}
          {dirty && problem && <p class="settings-note small error">{problem}</p>}
        </>}
        {status && <p class="settings-note muted small">{status}</p>}
        {err && <p class="settings-note small error">{err}</p>}
      </>}
    </section>
  )
}
