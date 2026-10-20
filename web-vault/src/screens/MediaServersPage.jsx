// Settings › Media Servers (iPhone BlossomSettingsView, "Other Servers"): the account's Blossom servers (BUD-03,
// kind 10063), where Compose uploads photos, with Remove and Add. Saving signs and publishes the new list.
import { useEffect, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { serverUrl, DEFAULT_MEDIA_SERVERS } from "../net/upload.js"
import { latestList, publishList, serverEntries, serverTags, addServer, removeServer, serverProblem, sameRows } from "../net/list-edit.js"

const loopback = url => { try { return /^(localhost|127\.|\[::1\])/.test(new URL(url).hostname) } catch { return false } }

export function MediaServersPage({ ctx }) {
  const readOnly = !!ctx.signer?.readOnly
  const [loaded, setLoaded] = useState(null) // { event, checked }
  const [urls, setUrls] = useState([])
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")

  // With no list of its own, the account uploads to the defaults, so an edit starts from them.
  const start = ev => ev ? serverEntries(ev) : DEFAULT_MEDIA_SERVERS
  useEffect(() => {
    latestList(ctx, 10063).then(r => { setLoaded(r); setUrls(start(r.event)) }).catch(e => { setLoaded({ event: undefined, checked: false }); setUrls(start()); setErr(String(e?.message ?? e)) })
  }, [])

  const saved = start(loaded?.event)
  const dirty = !!loaded && !sameRows(urls, saved)
  const problem = serverProblem(urls)

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
      setStatus(`Published to ${relays.filter(r => r.ok).length} of ${relays.length} relays. New photos go to ${serverEntries(event)[0]} first.`)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  if (!loaded) return <p class="empty">Loading…</p>
  return (
    <>
      <p class="settings-note muted small">Photos you attach to a note are uploaded here (Blossom), the first server first. Other apps read this list (BUD-03) to find your files.</p>
      {!loaded.checked && <p class="settings-note small error">Your relays couldn't be checked, so this may not be your newest list. Go online before you change it.</p>}
      {!loaded.event && loaded.checked && <p class="settings-note muted small">You haven't published a list, so the defaults below are used. Saving publishes them with your changes.</p>}
      {urls.map((url, i) => (
        <div key={url} class="settings-row static relay-edit-row">
          <span class="settings-title mono" title={url}>{url}</span>
          <span class="settings-tags">
            {i === 0 && <span class="tag">first</span>}
            {!loaded.event && DEFAULT_MEDIA_SERVERS.includes(url) && <span class="tag">default</span>}
            {serverUrl(url) === null && <span class="tag">not used</span>}
            {!readOnly && <button type="button" class="small relay-remove" disabled={busy} aria-label={`Remove ${url}`} onClick={() => setUrls(removeServer(urls, url))}>Remove</button>}
          </span>
        </div>
      ))}
      {readOnly ? <p class="settings-note muted small">{READ_ONLY}</p> : (
        <>
          <form class="settings-row static relay-add" onSubmit={add}>
            <input type="text" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck={false} placeholder="https://blossom.example.com" aria-label="Media server address" value={typed} onInput={e => setTyped(e.currentTarget.value)} disabled={busy} />
            <button type="submit" class="small" disabled={busy || !typed.trim()}>Add</button>
          </form>
          {dirty && (
            <div class="settings-note row">
              <button class="primary" disabled={busy || !!problem || !loaded.checked} onClick={save}>{busy ? "Publishing…" : "Save and publish"}</button>
              <button disabled={busy} onClick={() => { setUrls(saved); setErr("") }}>Discard changes</button>
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
