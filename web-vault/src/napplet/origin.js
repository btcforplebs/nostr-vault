// Where a napplet runs (plan P2): each napplet on its own origin, n-<first 32 hex of its artifact hash>.<napplet host>,
// so the loader can have a real origin. A real origin is what lets the loader cancel the napplet's own navigations
// (the Navigation API is off for opaque-origin documents) and put a network-blocking service worker in front of it,
// and a separate one per napplet keeps their storage and workers apart from each other and from the vault.
// The napplet host: the build's NV_NAPPLET_HOST (vite.config.js; e.g. "nvapps.example" -> https://n-<id>.nvapps.example),
// else, on localhost, "localhost" on the same port (Chrome and Firefox resolve *.localhost to this machine). Anywhere
// else there is none, and only our own napplets run (on the P1 loader, opaque origin): docs/napplets/P2_EMOJI.md.
// Pure: node tests pass `loc` and `host`.
// An outside napplet (anyone else's card) gets a label of its own per account (accountScope): the origin's storage
// (localStorage, IndexedDB, its service worker) is the origin's, so with the hash alone two accounts in one browser
// would share a card's saved data. Ours keep the hash label (they read each account through the shell, never their own
// storage, and the VPN preview lists their names).
export const NAPPLET_LABEL = /^n-([0-9a-f]{32})\./

/** The napplet origin for an artifact hash, or null when this site has no napplet host. */
export function nappletOrigin(hash, { loc = globalThis.location, host = configuredHost(), scope } = {}) {
  if (!/^[0-9a-f]{64}$/.test(hash ?? "") || !loc) return null
  if (scope !== undefined && !/^[0-9a-f]{32}$/.test(scope)) return null
  const id = `n-${scope ?? hash.slice(0, 32)}`
  if (host) return `https://${id}.${host}`
  if (loc.hostname === "localhost" || loc.hostname === "127.0.0.1") return `${loc.protocol}//${id}.localhost${loc.port ? `:${loc.port}` : ""}`
  return null
}

const SALT_KEY = account => `nv-napplet-origin-salt:${account}`

/** This browser's secret for an account, made once (16 random bytes, hex). Random, not the pubkey: a label made from
 *  the pubkey could be checked by the card against a list of npubs, and would tell it whose browser it is in. */
export function originSalt(storage, account) {
  if (!account) throw new Error("no account")
  const key = SALT_KEY(account)
  let salt = storage.getItem(key)
  if (!/^[0-9a-f]{32}$/.test(salt ?? "")) {
    salt = [...crypto.getRandomValues(new Uint8Array(16))].map(b => b.toString(16).padStart(2, "0")).join("")
    storage.setItem(key, salt)
  }
  return salt
}

/** An outside napplet's label for one account and one install: first 32 hex of sha256("<salt>:<hash>:<installedAt>").
 *  Another account (another salt) or a reinstall after Remove (another installedAt) starts with empty storage. */
export async function accountScope(hash, salt, installedAt = 0) {
  if (!/^[0-9a-f]{64}$/.test(hash ?? "") || !/^[0-9a-f]{32}$/.test(salt ?? "")) throw new Error("bad hash or salt")
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}:${hash}:${Number(installedAt) || 0}`))
  return [...new Uint8Array(d)].slice(0, 16).map(b => b.toString(16).padStart(2, "0")).join("")
}

/** For the servers: is this request Host a napplet origin? -> its parent host ("localhost:5173"), else null. */
export function nappletParentHost(hostHeader) {
  const h = String(hostHeader ?? "").toLowerCase()
  return NAPPLET_LABEL.test(h) ? h.replace(NAPPLET_LABEL, "") : null
}

function configuredHost() {
  try { return typeof __NV_NAPPLET_HOST__ === "string" ? __NV_NAPPLET_HOST__ : "" } catch { return "" }
}
