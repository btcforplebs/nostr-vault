// Box screen, Storage: the vault folder, how full its disk is, and Move vault to…. `state`: the storage call's
// { value } | { error }; `onMoved` reloads it after a move starts.
import { useState } from "preact/hooks"
import { Part, Row, Meter } from "./Parts.jsx"
import { bytes } from "../format.js"

export function StorageSection({ api, state, onMoved }) {
  const storage = state?.value
  return (
    <Part title="Storage" state={state}>
      {storage && <Storage api={api} storage={storage} onMoved={onMoved} />}
    </Part>
  )
}

function Storage({ api, storage, onMoved }) {
  const [moving, setMoving] = useState(false)
  const [path, setPath] = useState("")
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null) // { ok, text }
  const move = async e => {
    e.preventDefault()
    if (typeof confirm === "function" && !confirm(`Move your vault from ${storage.path} to ${path.trim()}? The box stops serving while it copies.`)) return
    setBusy(true); setMsg(null)
    try { const r = await api.move(path.trim()); setMsg({ ok: true, text: r.message || `Moving your vault to ${r.path || path.trim()}.` }); setMoving(false); onMoved() }
    catch (err) { setMsg({ ok: false, text: String(err?.message ?? err) }) }
    setBusy(false)
  }
  return (
    <div class="settings-rows">
      <Row label="Vault folder" value={storage.path || "—"} />
      <Meter label="Used" used={storage.used} total={storage.total} />
      <Row label="Free" value={bytes(storage.free)} />
      {storage.move_off ? <p class="muted small box-pad">This box's app store manages its disk, so the vault stays where it is.</p>
        : !moving ? <button type="button" class="settings-row box-action" onClick={() => setMoving(true)}>Move vault to…</button>
        : <form class="box-form" onSubmit={move}>
          <label class="field"><span>New folder on the box</span>
            <input value={path} onInput={e => setPath(e.currentTarget.value)} placeholder="/mnt/disk/nostr-vault" autocapitalize="off" spellcheck={false} />
          </label>
          <div class="box-buttons">
            <button type="button" class="small" onClick={() => setMoving(false)} disabled={busy}>Cancel</button>
            <button type="submit" class="small primary" disabled={busy || !path.trim()} aria-busy={busy || undefined}>{busy ? "Moving…" : "Move"}</button>
          </div>
        </form>}
      {msg && <p class={`small box-pad ${msg.ok ? "muted" : "error"}`} role={msg.ok ? "status" : "alert"}>{msg.text}</p>}
    </div>
  )
}
