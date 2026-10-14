export function ago(ts) {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts)
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  if (s < 30 * 86400) return `${Math.floor(s / 86400)}d`
  return new Date(ts * 1000).toLocaleDateString()
}
