// Which URLs the shell fetches for a napplet (NAP-RESOURCE). Pure. The napplet has no network of its own, so every
// fetch it gets goes out from this page, on the user's connection: never to the user's own network (a router's admin
// page, another device), never to a mesh (.fips) host (the vault's files come through Haven, P5), https only.
const PRIVATE_V4 = [/^10\./, /^127\./, /^0\./, /^169\.254\./, /^192\.168\./, /^172\.(1[6-9]|2\d|3[01])\./, /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./, /^(22[4-9]|2[3-5]\d)\./]
const LOCAL_NAMES = /(^|\.)(localhost|local|lan|home|internal|intranet|corp|fips|onion|arpa)$/i

/** -> null when the shell may fetch it for a napplet, else a NAP-RESOURCE error code. */
export function blockedUrl(raw) {
  let u
  try { u = new URL(raw) } catch { return "invalid-request" }
  if (u.protocol === "data:") return null
  if (u.protocol !== "https:") return "unsupported-scheme"
  if (u.username || u.password) return "blocked-by-policy"
  const host = u.hostname.toLowerCase().replace(/\.$/, "")
  if (!host.includes(".") || LOCAL_NAMES.test(host)) return "blocked-by-policy"
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host) && PRIVATE_V4.some(r => r.test(host))) return "blocked-by-policy"
  if (host.startsWith("[")) {
    const v6 = host.slice(1, -1)
    if (v6 === "::1" || v6 === "::" || /^f[cd]/.test(v6) || /^fe[89ab]/.test(v6) || /^::ffff:/.test(v6)) return "blocked-by-policy"
  }
  return null
}
