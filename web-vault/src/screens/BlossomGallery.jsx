// Vault › Media (iPhone MediaGalleryView): your files on your Blossom servers, by day, newest first, filtered to
// Photos, Videos or GIFs. A tile opens the file with Copy link, the servers that hold it, Copy to the servers missing
// it, and Delete (from every server, after asking). "In your notes" keeps the pictures your notes carry.
import { useEffect, useRef, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { mediaServers } from "../net/upload.js"
import { listBlobs, deleteBlob, mirrorBlob, outcome, byDay, TYPE_FILTERS } from "../net/blossom-gallery.js"

const hostOf = url => { try { return new URL(url).host } catch { return url } }
const EMPTY = { all: "No files on your media servers yet. Photos you attach to a note are uploaded there.", photos: "No photos on your media servers.", videos: "No videos on your media servers.", gifs: "No GIFs on your media servers." }

export function BlossomGallery({ ctx, filter = "all" }) {
  const [servers, setServers] = useState(null)
  const [found, setFound] = useState(null) // { blobs, status }
  const [open, setOpen] = useState(null) // sha256
  const [note, setNote] = useState("")
  const load = async () => {
    setFound(null)
    const s = await mediaServers(ctx).catch(() => [])
    setServers(s)
    setFound(await listBlobs(s, ctx.session.pubkey, { ctx }))
  }
  useEffect(() => { load() }, [ctx.session.pubkey])

  if (!found) return <p class="empty">Asking your media servers…</p>
  const blobs = found.blobs.filter(TYPE_FILTERS[filter] ?? TYPE_FILTERS.all)
  const down = Object.entries(found.status).filter(([, s]) => s !== "ok")
  const current = found.blobs.find(b => b.sha256 === open)
  const update = (sha, f) => setFound(x => ({ ...x, blobs: f(x.blobs) }))
  return (
    <div class="blossom">
      <div class="status-line">{found.blobs.length} file{found.blobs.length === 1 ? "" : "s"} on {servers.length - down.length} of {servers.length} server{servers.length === 1 ? "" : "s"}{down.length ? ` · ${down.map(([s, r]) => `${hostOf(s)}: ${r}`).join(" · ")}` : ""}</div>
      {note && <div class="status-line">{note}</div>}
      {!blobs.length ? <p class="empty">{EMPTY[filter] ?? EMPTY.all}</p> : byDay(blobs).map(g => (
        <section key={g.day}>
          <div class="section-label blossom-day">{g.day}</div>
          <div class="vault-grid">
            {g.blobs.map(b => (
              <button key={b.sha256} class="vault-thumb blossom-tile" onClick={() => setOpen(b.sha256)} aria-label={`${b.kind} uploaded ${g.day}`}>
                <Thumb blob={b} />
                {b.servers.length < servers.length && <span class="blossom-badge" title="Not on every server">{b.servers.length}/{servers.length}</span>}
              </button>
            ))}
          </div>
        </section>
      ))}
      {current && <Viewer ctx={ctx} blob={current} servers={servers} onClose={() => setOpen(null)}
        onDeleted={msg => { update(current.sha256, l => l.filter(b => b.sha256 !== current.sha256)); setOpen(null); setNote(msg) }}
        onMirrored={held => update(current.sha256, l => l.map(b => b.sha256 === current.sha256 ? { ...b, servers: held } : b))} />}
    </div>
  )
}

function Thumb({ blob, big = false }) {
  if (blob.kind === "video") return <video src={big ? blob.url : `${blob.url}#t=0.1`} preload="metadata" muted={!big} controls={big} playsinline />
  if (blob.kind === "other") return <span class="blossom-file">{(blob.type || "file").split("/").pop()}</span>
  return <img src={blob.url} alt="" loading={big ? "eager" : "lazy"} decoding="async" />
}

function Viewer({ ctx, blob, servers, onClose, onDeleted, onMirrored }) {
  const ref = useRef(null)
  const [busy, setBusy] = useState("")
  const [msg, setMsg] = useState("")
  const [asking, setAsking] = useState(false)
  const readOnly = !!ctx.signer?.readOnly
  useEffect(() => { const d = ref.current; if (d && !d.open) d.showModal?.(); return () => d?.open && d.close() }, [])
  const missing = servers.filter(s => !blob.servers.includes(s))
  const run = (label, f) => async () => {
    setBusy(label); setMsg("")
    try { await f() } catch (e) { setMsg(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const copy = run("copy", async () => { await navigator.clipboard.writeText(blob.url); setMsg("Link copied.") })
  const mirror = run("mirror", async () => {
    const r = await mirrorBlob(blob, servers, { ctx })
    onMirrored([...blob.servers, ...r.filter(x => x.ok).map(x => x.server)])
    setMsg(outcome(r, "Copied"))
  })
  const remove = run("delete", async () => {
    const r = await deleteBlob(blob, { ctx })
    if (r.some(x => x.ok)) onDeleted(outcome(r, "Deleted"))
    else setMsg(outcome(r, "Deleted"))
  })
  return (
    <dialog ref={ref} class="mod-dialog blossom-viewer" aria-label="File" onClose={onClose} onCancel={e => { e.preventDefault(); onClose() }}
      onClick={e => { if (e.target === ref.current) onClose() }}>
      <div class="mod-body">
        <div class="blossom-view"><Thumb blob={blob} big /></div>
        <div class="mono small blossom-url" title={blob.url}>{blob.url}</div>
        <div class="muted small">{blob.type || "file"}{blob.size ? ` · ${(blob.size / 1048576).toFixed(blob.size < 1048576 ? 2 : 1)} MB` : ""}</div>
        <div class="blossom-servers">
          {servers.map(s => <div key={s} class="small"><span class={blob.servers.includes(s) ? "ok" : "missing"}>{blob.servers.includes(s) ? "✓" : "–"}</span> {hostOf(s)}</div>)}
        </div>
        <div class="row">
          <button class="small" disabled={!!busy} onClick={copy}>Copy link</button>
          <a class="button small" href={blob.url} target="_blank" rel="noopener noreferrer">Open</a>
          {!readOnly && missing.length > 0 && <button class="small" disabled={!!busy} onClick={mirror}>{busy === "mirror" ? "Copying…" : `Copy to ${missing.length} more`}</button>}
        </div>
        {!readOnly && (asking
          ? <>
              <p class="muted small">Delete this file from {blob.servers.length === 1 ? hostOf(blob.servers[0]) : `all ${blob.servers.length} servers that hold it`}? Notes that show it will show a broken picture. This can't be undone.</p>
              <div class="row"><button class="danger small" disabled={!!busy} onClick={remove}>{busy === "delete" ? "Deleting…" : "Delete everywhere"}</button><button class="small" disabled={!!busy} onClick={() => setAsking(false)}>Cancel</button></div>
            </>
          : <button class="danger small" disabled={!!busy} onClick={() => setAsking(true)}>Delete…</button>)}
        {readOnly && <p class="muted small">{READ_ONLY}</p>}
        {msg && <p class="muted small">{msg}</p>}
        <button class="small" onClick={onClose}>Close</button>
      </div>
    </dialog>
  )
}
