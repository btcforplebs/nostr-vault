// Where a napplet runs (plan P2): each napplet on its own origin, n-<first 32 hex of its artifact hash>.<napplet host>,
// so the loader can have a real origin. A real origin is what lets the loader cancel the napplet's own navigations
// (the Navigation API is off for opaque-origin documents) and put a network-blocking service worker in front of it,
// and a separate one per napplet keeps their storage and workers apart from each other and from the vault.
// The napplet host: the build's NV_NAPPLET_HOST (vite.config.js; e.g. "nvapps.example" -> https://n-<id>.nvapps.example),
// else, on localhost, "localhost" on the same port (Chrome and Firefox resolve *.localhost to this machine). Anywhere
// else there is none, and only our own napplets run (on the P1 loader, opaque origin): docs/napplets/P2_EMOJI.md.
// Pure: node tests pass `loc` and `host`.
export const NAPPLET_LABEL = /^n-([0-9a-f]{32})\./

/** The napplet origin for an artifact hash, or null when this site has no napplet host. */
export function nappletOrigin(hash, { loc = globalThis.location, host = configuredHost() } = {}) {
  if (!/^[0-9a-f]{64}$/.test(hash ?? "") || !loc) return null
  const id = `n-${hash.slice(0, 32)}`
  if (host) return `https://${id}.${host}`
  if (loc.hostname === "localhost" || loc.hostname === "127.0.0.1") return `${loc.protocol}//${id}.localhost${loc.port ? `:${loc.port}` : ""}`
  return null
}

/** For the servers: is this request Host a napplet origin? -> its parent host ("localhost:5173"), else null. */
export function nappletParentHost(hostHeader) {
  const h = String(hostHeader ?? "").toLowerCase()
  return NAPPLET_LABEL.test(h) ? h.replace(NAPPLET_LABEL, "") : null
}

function configuredHost() {
  try { return typeof __NV_NAPPLET_HOST__ === "string" ? __NV_NAPPLET_HOST__ : "" } catch { return "" }
}
