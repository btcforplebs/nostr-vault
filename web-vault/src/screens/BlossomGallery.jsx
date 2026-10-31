// Vault › Media (iPhone MediaGalleryView): your files on your Blossom servers, filtered to Photos, Videos or GIFs and
// sorted Newest first (by day), Oldest first (by day) or by Media type, as the iPhone's MediaSortOption. Every tile
// says how many of your servers hold it. A tile opens the file with Copy link, the servers that hold it, Copy to the servers missing
// it, and Delete from mirrors (every media server, any other that listed it and the server in its link, after asking). "In your notes" keeps the pictures your notes carry.
import { useEffect, useRef, useState } from "preact/hooks"
import { READ_ONLY } from "../signer/readonly.js"
import { mediaServers } from "../net/upload.js"
import { BlossomStats } from "./BlossomStats.jsx"
import { BlossomUpload } from "./BlossomUpload.jsx"
import { listBlobs, deleteBlob, deleteTargets, mirrorBlob, outcome, byDay, TYPE_FILTERS } from "../net/blossom-gallery.js"
import { SkeletonGrid, Waiting } from "../components/Loading.jsx"
if (import.meta.env) import("../styles/blossom.css")

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
export function sections(blobs, sort, locale, now) {
  if (sort === "type") return blobs.length ? [{ day: "", blobs: [...blobs].sort((a, b) => typeRank(a) - typeRank(b) || b.uploaded - a.uploaded) }] : []
  return byDay([...blobs].sort((a, b) => (sort === "oldest" ? a.uploaded - b.uploaded : b.uploaded - a.uploaded)), locale, now)
}

const SERVERS_KEY = "nv-gallery-servers:"
export const rememberedServers = (pubkey, storage = globalThis.localStorage) => { try { const s = JSON.parse(storage?.getItem(SERVERS_KEY + pubkey) ?? "null"); return Array.isArray(s) && s.length && s.every(x => typeof x === "string") ? s : null } catch { return null } }
const rememberServers = (pubkey, s, storage = globalThis.localStorage) => { try { storage?.setItem(SERVERS_KEY + pubkey, JSON.stringify(s)) } catch {} }

// The last full list per account, for this tab's life: opening Media again draws it and doesn't ask the servers
// again (each /list may want a signed auth) until Refresh, or until it is MEDIA_FRESH_MS old: an upload made from
// Compose then shows on a later visit.
const shown = new Map() // pubkey -> { servers, found, at }
export const MEDIA_FRESH_MS = 5 * 60_000
/** Whether opening Media asks the servers: no list kept this visit, or the kept one is old. */
export const needsAsking = (kept, now = Date.now()) => !kept || !(now - (kept.at ?? 0) < MEDIA_FRESH_MS)

export function BlossomGallery({ ctx, filter = "all", refreshes = 0 }) {
  const me = ctx.session.pubkey
  const [servers, setServers] = useState(() => shown.get(me)?.servers ?? null)
  const [found, setFound] = useState(() => shown.get(me)?.found ?? null) // { blobs, status, done }
  const [open, setOpen] = useState(null) // sha256
  const [note, setNote] = useState("")
  const [sort, setSort] = useState(loadSort)
  const runs = useRef(0) // only the newest listing may draw
  const load = async () => {
    const run = ++runs.current
    // With a list on screen, the new one replaces it only when every server has answered: a partial list would drop
    // the files the slower servers hold, then put them back.
    const quiet = !!shown.get(me)
    let asking = null // the server list whose answers may draw
    const list = s => { asking = s; return listBlobs(s, me, { ctx, on: quiet ? undefined : p => run === runs.current && asking === s && setFound({ ...p, done: false }) }) }
    // The servers this browser last used are asked while the account's list (kind 10063) is looked up; asked again
    // only if that list says otherwise.
    const was = rememberedServers(me)
    const early = was && !quiet ? (setServers(was), list(was)) : null
    const s = await mediaServers(ctx).catch(() => [])
    rememberServers(me, s)
    const same = was && s.length === was.length && s.every((x, i) => x === was[i])
    if (!quiet && !same) setServers(s)
    const r = early && same ? await early : await list(s)
    if (run !== runs.current) return
    shown.set(me, { servers: s, found: { ...r, done: true }, at: Date.now() })
    setServers(s); setFound({ ...r, done: true })
  }
  const drawn = useRef(null) // the account this card last opened for
  useEffect(() => {
    const entering = drawn.current !== me
    drawn.current = me
    // Opening Media again draws the kept list without asking; Refresh (refreshes) always asks.
    if (entering && !needsAsking(shown.get(me))) return
    load()
  }, [me, refreshes])
  // Uploads, deletes and copies change the list on screen; the kept one follows (its age doesn't).
  useEffect(() => { if (found?.done) shown.set(me, { servers, found, at: shown.get(me)?.at ?? Date.now() }) }, [found])

  if (!found || (!found.done && !found.blobs.length)) return <><Waiting>Loading media…</Waiting><SkeletonGrid count={12} gridClass="vault-grid" tileClass="vault-thumb blossom-tile" label="Asking your media servers" /></>
  const blobs = found.blobs.filter(TYPE_FILTERS[filter] ?? TYPE_FILTERS.all)
  const groups = sections(blobs, sort)
  const order = groups.flatMap(g => g.blobs) // the viewer steps through the grid's order
  const current = found.blobs.find(b => b.sha256 === open)
  const update = (sha, f) => setFound(x => ({ ...x, blobs: f(x.blobs) }))
  return (
    <div class="blossom">
      <BlossomStats blobs={found.blobs} servers={servers} status={found.status} pending={!found.done} />
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
        : groups.map(g => (
        <section key={g.day || "all"}>
          {g.day && <div class="section-label blossom-day">{g.day}</div>}
          <div class="vault-grid">
            {g.blobs.map(b => (
              <button key={b.sha256} class="vault-thumb blossom-tile" onClick={() => setOpen(b.sha256)} aria-label={`${isAudio(b) ? "audio" : b.kind}${g.day ? ` uploaded ${g.day}` : ""}`}>
                <Thumb blob={b} />
                {b.kind === "video" && <span class="blossom-play" aria-hidden="true"><svg viewBox="0 0 24 24" width="22" height="22"><path d="M8 5.5v13l11-6.5z" fill="currentColor" /></svg></span>}
                {servers.length > 0 && <span class="blossom-badge" title={b.servers.length < servers.length ? "Not on every server" : "On every server"}>{b.servers.length}/{servers.length}</span>}
              </button>
            ))}
          </div>
        </section>
      ))}
      {current && <Viewer ctx={ctx} blob={current} servers={servers} order={order} onStep={setOpen} onClose={() => setOpen(null)}
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

/** The file before / after `sha` in the grid's order, or null at either end. */
export const neighbour = (order, sha, step) => { const i = order.findIndex(b => b.sha256 === sha); return i < 0 ? null : order[i + step]?.sha256 ?? null }

function Viewer({ ctx, blob, servers, order = [], onStep, onClose, onDeleted, onMirrored }) {
  const ref = useRef(null)
  const [busy, setBusy] = useState("")
  const [msg, setMsg] = useState("")
  const [asking, setAsking] = useState(false)
  const swipe = useRef(null)
  const readOnly = !!ctx.signer?.readOnly
  useEffect(() => { const d = ref.current; if (d && !d.open) d.showModal?.(); return () => d?.open && d.close() }, [])
  useEffect(() => { setMsg(""); setAsking(false) }, [blob.sha256])
  // Previous and next as the phone's swipe: the arrows, the arrow keys, or a sideways swipe on the picture.
  const prev = neighbour(order, blob.sha256, -1), next = neighbour(order, blob.sha256, 1)
  const step = sha => { if (sha && !busy) onStep(sha) }
  const keys = e => { if (e.key === "ArrowLeft") step(prev); else if (e.key === "ArrowRight") step(next) }
  const touchStart = e => { swipe.current = e.touches[0]?.clientX ?? null }
  const touchEnd = e => { const x = e.changedTouches[0]?.clientX; if (swipe.current != null && x != null && Math.abs(x - swipe.current) > 50) step(x < swipe.current ? next : prev); swipe.current = null }
  const missing = servers.filter(s => !blob.servers.includes(s))
  const targets = deleteTargets(blob, servers)
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
    const r = await deleteBlob(blob, { ctx, servers })
    if (r.some(x => x.ok)) onDeleted(outcome(r, "Deleted"))
    else setMsg(outcome(r, "Deleted"))
  })
  return (
    <dialog ref={ref} class="mod-dialog blossom-viewer" aria-label="File" onClose={onClose} onCancel={e => { e.preventDefault(); onClose() }} onKeyDown={keys}
      onClick={e => { if (e.target === ref.current) onClose() }}>
      <div class="mod-body">
        <div class="blossom-view" onTouchStart={touchStart} onTouchEnd={touchEnd}>
          <Thumb blob={blob} big />
          {prev && <button class="blossom-step prev" aria-label="Previous file" disabled={!!busy} onClick={() => step(prev)}>‹</button>}
          {next && <button class="blossom-step next" aria-label="Next file" disabled={!!busy} onClick={() => step(next)}>›</button>}
        </div>
        <div class="mono small blossom-url" title={blob.url}>{blob.url}</div>
        <div class="muted small">{blob.type || "file"}{blob.size ? ` · ${(blob.size / 1048576).toFixed(blob.size < 1048576 ? 2 : 1)} MB` : ""}</div>
        <div class="blossom-servers">
          {servers.map(s => <div key={s} class="small"><span class={blob.servers.includes(s) ? "ok" : "missing"}>{blob.servers.includes(s) ? "✓" : "–"}</span> {hostOf(s)}</div>)}
        </div>
        <div class="row">
          <button class="small" disabled={!!busy} onClick={copy}>Copy link</button>
          <a class="button small" href={blob.url} target="_blank" rel="noopener noreferrer">Open</a>
          {!readOnly && missing.length > 0 && <button class="small" disabled={!!busy} onClick={mirror} aria-busy={busy === "mirror" || undefined}>{busy === "mirror" ? "Copying…" : `Copy to ${missing.length} more`}</button>}
        </div>
        {!readOnly && (asking
          ? <>
              <p class="muted small">Delete this file from {targets.length === 1 ? hostOf(targets[0]) : `${targets.length} servers: ${targets.map(hostOf).join(", ")}`}? Notes that show it will show a broken picture. This can't be undone.</p>
              <p class="muted small">If your home vault (Nostr Vault on your Mac) has a copy, it stays: the web can't delete from it. Delete it there with Delete everywhere.</p>
              <div class="row"><button class="danger small" disabled={!!busy} onClick={remove} aria-busy={busy === "delete" || undefined}>{busy === "delete" ? "Deleting…" : "Delete from mirrors"}</button><button class="small" disabled={!!busy} onClick={() => setAsking(false)}>Cancel</button></div>
            </>
          : <button class="danger small" disabled={!!busy} onClick={() => setAsking(true)}>Delete…</button>)}
        {readOnly && <p class="muted small">{READ_ONLY}</p>}
        {msg && <p class="muted small">{msg}</p>}
        <button class="small" onClick={onClose}>Close</button>
      </div>
    </dialog>
  )
}
