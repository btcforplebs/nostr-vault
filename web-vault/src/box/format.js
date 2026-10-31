// Numbers on the box screens. Unknown (missing) reads as "—", never as 0.
export const bytes = n => {
  if (!Number.isFinite(n) || n < 0) return "—"
  const u = ["B", "KB", "MB", "GB", "TB"]
  let i = 0
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++ }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`
}
export const uptime = s => {
  if (!Number.isFinite(s) || s < 0) return "—"
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`
}
export const share = (used, total) => Number.isFinite(used) && Number.isFinite(total) && total > 0 ? Math.min(1, used / total) : null
export const ago = (sec, now = Date.now() / 1000) => {
  if (!Number.isFinite(sec)) return "never"
  const s = Math.max(0, now - sec)
  return s < 90 ? "just now" : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 129600 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} days ago`
}
export const shortNpub = n => typeof n === "string" && n.length > 20 ? `${n.slice(0, 12)}…${n.slice(-6)}` : n || "—"
