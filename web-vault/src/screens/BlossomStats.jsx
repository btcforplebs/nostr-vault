// The top of Vault › Media, as the iPhone's Blossom dashboard sums it up (BlossomDashboardComponents StatsSection,
// MirrorStatusSection): Total Files, Storage Used, Active Mirrors and Backed Up (on every one of your servers), then
// each server with a green / red dot. Reading only: Pull and Backup sign, and aren't here.
const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** "1.2 GB", as the iPhone's ByteCountFormatter (.file: 1000s, one decimal past MB). */
export function formatBytes(n) {
  if (!(n > 0)) return "Zero KB"
  const units = ["bytes", "KB", "MB", "GB", "TB"]
  let i = 0, v = n
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++ }
  return i === 0 ? `${v} bytes` : `${i >= 2 ? v.toFixed(1).replace(/\.0$/, "") : Math.round(v)} ${units[i]}`
}

/** -> { totalFiles, size, mirrors, answering, backedUp, percent } from the merged list and each server's status. A
 *  server that didn't answer could hold anything, so then Backed Up is unknown (percent null), not 0. */
export function galleryStats(blobs, servers, status) {
  const answering = servers.filter(s => status[s] === "ok").length
  const backedUp = blobs.filter(b => servers.length > 0 && servers.every(s => b.servers.includes(s))).length
  return {
    totalFiles: blobs.length, size: blobs.reduce((n, b) => n + (b.size || 0), 0), mirrors: servers.length, answering,
    backedUp, percent: answering < servers.length ? null : blobs.length ? Math.floor((backedUp / blobs.length) * 100) : 0,
  }
}

// Inline: the gallery's stylesheet is src/styles/settings.css, which another lane owns.
const S = {
  wrap: { margin: "4px var(--gutter, 16px) 12px" },
  grid: { display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: 8 },
  stat: { display: "flex", flexDirection: "column", gap: 2, padding: "10px 8px", borderRadius: 12, background: "var(--s1)", border: "1px solid var(--hair)", minWidth: 0 },
  value: { fontSize: 17, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  mirrors: { marginTop: 8, padding: "8px 12px", borderRadius: 12, background: "var(--s1)", border: "1px solid var(--hair)" },
  row: { display: "flex", alignItems: "center", gap: 8, padding: "6px 0" },
  dot: ok => ({ width: 6, height: 6, borderRadius: "50%", flex: "none", background: ok ? "var(--online, #33d980)" : "var(--danger, #ff453a)" }),
  host: { flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
}

/** Healthy, Offline (no answer at all), or Refused with the server's reason: it answered, but not with a list. */
export const health = st => (st === "ok" ? "Healthy" : !st || st === "didn't answer" || /fetch|network/i.test(st) ? "Offline" : `Refused · ${st}`)

export function BlossomStats({ blobs, servers, status }) {
  const s = galleryStats(blobs, servers, status)
  const tiles = [["Total Files", s.totalFiles.toLocaleString()], ["Storage Used", formatBytes(s.size)], ["Active Mirrors", `${s.answering}/${s.mirrors}`], ["Backed Up", s.percent == null ? "?" : `${s.percent}%`]]
  return (
    <section class="blossom-stats" aria-label="Media servers" style={S.wrap}>
      <div class="blossom-stat-grid" style={S.grid}>{tiles.map(([t, v]) => <div key={t} class="blossom-stat" style={S.stat}><span class="muted small">{t}</span><strong style={S.value}>{v}</strong></div>)}</div>
      {servers.length > 0 && (
        <details class="blossom-mirrors" style={S.mirrors}>
          <summary class="small">{servers.length} configured{s.percent == null ? ` · ${s.mirrors - s.answering} didn't list your files, so Backed Up can't be told`
            : s.backedUp < s.totalFiles ? ` · ${(s.totalFiles - s.backedUp).toLocaleString()} not on every server` : ""}</summary>
          {servers.map(sv => (
            <div key={sv} class="blossom-mirror small" style={S.row}>
              <span class={`blossom-dot ${status[sv] === "ok" ? "ok" : "down"}`} style={S.dot(status[sv] === "ok")} aria-hidden="true" />
              <span class="mono" style={S.host}>{hostOf(sv)}</span>
              <span class={status[sv] === "ok" ? "ok" : "muted"}>{health(status[sv])}</span>
            </div>
          ))}
        </details>
      )}
    </section>
  )
}
