// The box screens (#/box), as the Mac app's: Status, Storage (Move vault to…), Mesh, My Devices and Update, read from the
// box's owner-only API (api.js). Shown only in box mode (mode.js). Each part loads on its own, so a slow or refused
// call leaves the others showing; an unknown number reads "—", never 0.
import { useEffect, useMemo, useState } from "preact/hooks"
import { boxApi } from "./api.js"
import { bytes, uptime, share, ago, shortNpub } from "./format.js"
if (import.meta.env) import("./box.css")

const ROLE = { mac: "Home vault · full history", phone: "Phone", homeVault: "Home vault · new posts", browser: "Browser vault" }

/** `api`: a boxApi; built from the signer when not given (tests and the harness pass one over a mock). */
export function BoxScreen({ ctx, api: given }) {
  const api = useMemo(() => given ?? boxApi({ signer: ctx.signer }), [given, ctx.signer])
  const [data, setData] = useState({}) // part -> { value } | { error }
  const load = part => api[part]().then(value => setData(d => ({ ...d, [part]: { value } })), e => setData(d => ({ ...d, [part]: { error: String(e?.message ?? e) } })))
  useEffect(() => { for (const p of ["status", "storage", "devices"]) load(p) }, [api])
  const status = data.status?.value, storage = data.storage?.value, devices = data.devices?.value
  return (
    <div class="screen box-screen">
      <header class="screen-head"><a class="button small" href="#/settings">‹ Settings</a><h2>Box</h2><span style="width: 92px" /></header>
      <Part title="Status" state={data.status}>
        {status && <div class="settings-rows">
          <Row label="Running" value={`for ${uptime(status.uptime)}`} />
          <Row label="Version" value={status.version || "—"} />
          <Meter label="Memory" used={status.mem?.used} total={status.mem?.total} />
          <Meter label="Disk" used={status.disk?.used} total={status.disk?.total} />
        </div>}
      </Part>
      <Part title="Storage" state={data.storage}>
        {storage && <Storage api={api} storage={storage} onMoved={() => load("storage")} />}
      </Part>
      <Part title="Mesh" state={data.status}>
        {status && <div class="settings-rows">
          <Row label="Mesh" value={status.mesh?.up === true ? "Connected" : status.mesh?.up === false ? "Not connected" : "—"} tone={status.mesh?.up ? "good" : ""} />
          <Row label="Peers" value={Number.isFinite(status.mesh?.peers) ? String(status.mesh.peers) : "—"} />
          <Row label="Mesh address" value={shortNpub(status.mesh?.npub)} copy={status.mesh?.npub} />
        </div>}
      </Part>
      <Part title="My Devices" state={data.devices}>
        {devices && <Devices devices={devices} />}
      </Part>
      <Part title="Update" state={data.status}>
        {status && <Update api={api} version={status.version} />}
      </Part>
    </div>
  )
}

function Part({ title, state, children }) {
  return (
    <section class="settings-group">
      <div class="section-label">{title}</div>
      {!state ? <p class="muted small box-pad">Asking the box…</p>
        : state.error ? <p class="error small box-pad" role="alert">{state.error}</p>
        : children}
    </section>
  )
}

function Row({ label, value, tone = "", copy }) {
  const [copied, setCopied] = useState(false)
  return (
    <div class="settings-row box-row">
      <span class="settings-title">{label}</span>
      <span class={`box-value ${tone}`}>{value}</span>
      {copy && <button type="button" class="small" onClick={() => navigator.clipboard?.writeText(copy).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1200) })}>{copied ? "Copied" : "Copy"}</button>}
    </div>
  )
}

function Meter({ label, used, total }) {
  const s = share(used, total)
  return (
    <div class="settings-row box-row box-meter-row">
      <span class="settings-title">{label}</span>
      <span class="box-value">{bytes(used)} of {bytes(total)}</span>
      <span class="box-meter" role="meter" aria-label={label} aria-valuemin="0" aria-valuemax="100" aria-valuenow={s == null ? undefined : Math.round(s * 100)}>
        <span style={{ width: s == null ? 0 : `${Math.round(s * 100)}%` }} class={s != null && s > 0.9 ? "full" : ""} />
      </span>
    </div>
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
      {!moving ? <button type="button" class="settings-row box-action" onClick={() => setMoving(true)}>Move vault to…</button>
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

function Devices({ devices }) {
  const box = devices.box ?? {}
  const list = Array.isArray(devices.devices) ? devices.devices : []
  return (
    <div class="settings-rows">
      <Row label="This box" value={shortNpub(box.npub)} copy={box.npub} />
      <p class="muted small box-pad">To approve it, open My Devices on your phone or Mac and add this box as a home vault (Home vault · new posts). The box has no key of yours; it only stores and passes on what you sign.</p>
      {list.length === 0 && <p class="muted small box-pad">No devices of yours have reached the box yet.</p>}
      {list.map(d => (
        <div key={d.npub} class="settings-row box-row">
          <span class="settings-title">{d.name?.trim() || ROLE[d.role] || "Device"}<span class="muted small box-sub">{[d.name?.trim() && ROLE[d.role], Number.isFinite(d.lastSeen) && `seen ${ago(d.lastSeen)}`].filter(Boolean).join(" · ")}</span></span>
          <span class={`box-value ${d.approved ? "good" : ""}`}>{d.approved ? "Approved" : "Waiting"}</span>
        </div>
      ))}
    </div>
  )
}

function Update({ api, version }) {
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const run = async () => {
    setBusy(true); setMsg(null)
    try {
      const r = await api.update()
      setMsg({ ok: true, text: [r.to ? `Updating ${r.from || version} to ${r.to}.` : "Update started.", r.rollback].filter(Boolean).join(" ") })
    } catch (e) { setMsg({ ok: false, text: String(e?.message ?? e) }) }
    setBusy(false)
  }
  return (
    <div class="settings-rows">
      <Row label="Running" value={version ? `Version ${version}` : "—"} />
      <button type="button" class="settings-row box-action" disabled={busy} aria-busy={busy || undefined} onClick={run}>{busy ? "Asking the box…" : "Check for update and install"}</button>
      <p class="muted small box-pad">The box keeps the version it runs now, so it can go back to it if a new one won't start.</p>
      {msg && <p class={`small box-pad ${msg.ok ? "muted" : "error"}`} role={msg.ok ? "status" : "alert"}>{msg.text}</p>}
    </div>
  )
}
