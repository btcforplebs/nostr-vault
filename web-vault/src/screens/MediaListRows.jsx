// Vault › Media as a list (the iPhone's MediaListItem, RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md W1): one row per file
// with its thumbnail, type, size, upload date and how many of your servers hold it ("2/3 servers"). The grid's tile
// opens the same viewer; `thumb(blob)` is the grid's own thumbnail, so a row loads its picture the same lazy way.
import { useEffect, useRef, useState } from "preact/hooks"
import { blobSizeStore } from "../net/blob-size.js"

/** "2.4 MB", "830 KB", "512 B"; "" when the server gave no size. */
export function sizeLabel(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return ""
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1048576) return `${Math.round(bytes / 1024)} KB`
  if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MB`
  return `${(bytes / 1073741824).toFixed(2)} GB`
}

/** Photo, GIF, Video, Audio, else the file's MIME type (or "File"). */
export function typeLabel(b) {
  if (b.kind === "photo") return "Photo"
  if (b.kind === "gif") return "GIF"
  if (b.kind === "video") return "Video"
  if (b.kind === "audio" || /^audio\//i.test(b.type ?? "")) return "Audio"
  return b.type || "File"
}

/** "3 Nov 2026" from an upload time in seconds; "" when unknown. */
export function dateLabel(uploaded, locale) {
  if (!Number.isFinite(uploaded) || uploaded <= 0) return ""
  return new Date(uploaded * 1000).toLocaleDateString(locale, { day: "numeric", month: "short", year: "numeric" })
}

/** "2/3 servers", or "New" for a file only a note has carried so far; "" with no servers known. */
export function serversLabel(b, servers) {
  if (b.fromNote) return "New"
  if (!servers?.length) return ""
  return `${b.servers?.length ?? 0}/${servers.length} servers`
}

/** The row's detail line: "Video · 2.4 MB · 3 Nov 2026", leaving out what isn't known. */
export const detailLine = (b, locale) => [typeLabel(b), sizeLabel(b.size), dateLabel(b.uploaded, locale)].filter(Boolean).join(" · ")

const row = { display: "flex", alignItems: "center", gap: 12, width: "100%", padding: "8px 4px", background: "none", border: "none",
  borderBottom: "1px solid var(--line, rgba(127,127,127,.2))", color: "inherit", font: "inherit", textAlign: "left", cursor: "pointer" }
const thumbBox = { flex: "0 0 56px", width: 56, height: 56, borderRadius: 8, overflow: "hidden", display: "flex", alignItems: "center", justifyContent: "center", background: "var(--s1, rgba(127,127,127,.12))" }

export function MediaListRows({ blobs, servers, thumb, onOpen, locale }) {
  return (
    <div class="blossom-list" role="list">
      {blobs.map(b => <Row key={b.sha256} blob={b} servers={servers} thumb={thumb} onOpen={onOpen} locale={locale} />)}
    </div>
  )
}

/** The size to show: the list's or note's, else one this browser learned (net/blob-size.js), else asked of the
 *  file's server once the row comes on screen (Z1). Unknown stays blank, never "0". */
export function useRowSize(blob, ref, store = blobSizeStore()) {
  const [size, setSize] = useState(() => blob.size || store.cached(blob.sha256) || 0)
  useEffect(() => {
    if (size > 0) return
    let alive = true
    const ask = () => store.size(blob.sha256, blob.url).then(n => { if (alive && n) setSize(n) })
    let seen = null
    if (typeof IntersectionObserver === "function" && ref.current) {
      seen = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { seen.disconnect(); ask() } })
      seen.observe(ref.current)
    } else ask()
    return () => { alive = false; seen?.disconnect() }
  }, [blob.sha256, blob.url])
  return size
}

function Row(props) {
  const ref = useRef(null)
  return <RowView {...props} size={useRowSize(props.blob, ref)} rowRef={ref} />
}

/** One row as drawn, with `size` already settled. */
export function RowView({ blob: b, servers, thumb, onOpen, locale, size = b.size, rowRef }) {
  const where = serversLabel(b, servers)
  const shown = size === b.size ? b : { ...b, size }
  return (
    <button ref={rowRef} type="button" role="listitem" class="blossom-row" style={row} onClick={() => onOpen(b.sha256)}
      aria-label={`${typeLabel(b)}${size ? `, ${sizeLabel(size)}` : ""}`}>
      <span class="blossom-row-thumb" style={thumbBox}>{thumb(b)}</span>
      <span style={{ flex: "1 1 auto", minWidth: 0 }}>
        <span class="small" style={{ display: "block" }}>{detailLine(shown, locale)}</span>
        {where && <span class="muted small" style={{ display: "block" }} title={b.fromNote ? "Just added from one of your devices" : b.servers.length < servers.length ? "Not on every server" : "On every server"}>{where}</span>}
      </span>
    </button>
  )
}
