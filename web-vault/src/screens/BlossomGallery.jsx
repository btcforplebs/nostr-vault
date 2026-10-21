// Vault › Media (iPhone MediaGalleryView): your files on your Blossom servers, filtered to Photos, Videos or GIFs and
// sorted Newest first (by day), Oldest first (by day) or by Media type, as the iPhone's MediaSortOption. Every tile
// says how many of your servers hold it. A tile opens the file with Copy link, the servers that hold it, Copy to the servers missing
// it, and Delete (from every server, after asking). "In your notes" keeps the pictures your notes carry.
import { useEffect, useRef, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { mediaServers } from "../net/upload.js"
import { BlossomStats } from "./BlossomStats.jsx"
import { BlossomUpload } from "./BlossomUpload.jsx"
import { listBlobs, deleteBlob, mirrorBlob, outcome, byDay, TYPE_FILTERS } from "../net/blossom-gallery.js"

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** The iPhone's sorts, less "On relay first": the web has no relay-held media to put first. */
export const SORTS = [{ id: "newest", label: "Newest first" }, { id: "oldest", label: "Oldest first" }, { id: "type", label: "Media type" }]
const SORT_KEY = "nv-gallery-sort"
export const loadSort = (storage = globalThis.localStorage) => { const s = storage?.getItem(SORT_KEY); return SORTS.some(x => x.id === s) ? s : "newest" }
const saveSort = (s, storage = globalThis.localStorage) => { try { storage?.setItem(SORT_KEY, s) } catch {} }

/** Photos, GIFs, videos, audio, then anything else (MediaGalleryView.typeRank). */
export const isAudio = b => b.kind === "other" && /^audio\//i.test(b.type ?? "")
export const typeRank = b => ({ photo: 0, gif: 1, video: 2 })[b.kind] ?? (isAudio(b) ? 3 : 4)

/** The files in `sort` order, as sections: dated runs for the date sorts, one untitled run otherwise. */
export function sections(blobs, sort, locale) {
  if (sort === "type") return blobs.length ? [{ day: "", blobs: [...blobs].sort((a, b) => typeRank(a) - typeRank(b) || b.uploaded - a.uploaded) }] : []
  return byDay([...blobs].sort((a, b) => (sort === "oldest" ? a.uploaded - b.uploaded : b.uploaded - a.uploaded)), locale)
}

export function BlossomGallery({ ctx, filter = "all", refreshes = 0 }) {
  const [servers, setServers] = useState(null)
  const [found, setFound] = useState(null) // { blobs, status }
  const [open, setOpen] = useState(null) // sha256
  const [note, setNote] = useState("")
  const [sort, setSort] = useState(loadSort)
  const load = async () => {
    setFound(null)
    const s = await mediaServers(ctx).catch(() => [])
    setServers(s)
    setFound(await listBlobs(s, ctx.session.pubkey, { ctx }))
  }
  useEffect(() => { load() }, [ctx.session.pubkey, refreshes])

  if (!found) return <div class="empty"><p><strong>Loading media…</strong></p><p class="muted small">Asking your media servers</p></div>
  const blobs = found.blobs.filter(TYPE_FILTERS[filter] ?? TYPE_FILTERS.all)
  const current = found.blobs.find(b => b.sha256 === open)
  const update = (sha, f) => setFound(x => ({ ...x, blobs: f(x.blobs) }))
  return (
    <div class="blossom">
      <BlossomStats blobs={found.blobs} servers={servers} status={found.status} />
      <BlossomUpload ctx={ctx} servers={servers} onAdded={added => setFound(x => ({ ...x, blobs: [...added, ...x.blobs.filter(b => !added.some(a => a.sha256 === b.sha256))] }))} />
      {note && <div class="status-line">{note}</div>}
      {found.blobs.length > 1 && (
        <label class="status-line blossom-sort">Sort by{" "}
          <select value={sort} onChange={e => { setSort(e.currentTarget.value); saveSort(e.currentTarget.value) }}>
            {SORTS.map(x => <option key={x.id} value={x.id}>{x.label}</option>)}
          </select>
        </label>
      )}
      {!blobs.length ? <div class="empty"><p><strong>No media found</strong></p>{found.blobs.length > 0 && <p class="muted small">Try changing your filter settings</p>}</div>
        : sections(blobs, sort).map(g => (
        <section key={g.day || "all"}>
          {g.day && <div class="section-label blossom-day">{g.day}</div>}
          <div class="vault-grid">
            {g.blobs.map(b => (
              <button key={b.sha256} class="vault-thumb blossom-tile" onClick={() => setOpen(b.sha256)} aria-label={`${isAudio(b) ? "audio" : b.kind}${g.day ? ` uploaded ${g.day}` : ""}`}>
                <Thumb blob={b} />
                {servers.length > 0 && <span class="blossom-badge" title={b.servers.length < servers.length ? "Not on every server" : "On every server"}>{b.servers.length}/{servers.length}</span>}
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
  if (blob.kind === "other") return <span class="blossom-file" style={{ overflowWrap: "anywhere", textAlign: "center", padding: 4 }}>{isAudio(blob) ? "♪ " : ""}{blob.type || "file"}</span>
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
