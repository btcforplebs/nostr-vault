// Who is signed in, and how: { pubkey, method: "nip07" | "nip46" | "readonly", bunker?, clientSkSealed? }. Never the user's secret
// key. "nv-session" is the active account; "nv-accounts" every account this browser remembers (Accounts screen), the
// active one included. A bunker account's client key is sealed (signer/keyring.js), never stored as plain hex.
const KEY = "nv-session"
const ACCOUNTS = "nv-accounts"
const PUBKEY = /^[0-9a-f]{64}$/

/** A signer's pubkey must be 64 lowercase hex characters before it goes into the session. */
export function checkedPubkey(pk) {
  if (typeof pk === "string" && PUBKEY.test(pk)) return pk
  throw new Error("Your signer sent back something that isn't a public key. Try again, or use another signer.")
}

const METHODS = ["nip07", "nip46", "readonly"]
const valid = s => !!s && PUBKEY.test(s.pubkey) && METHODS.includes(s.method)

/** How a session signs, as the screens say it: "with a browser extension", "read-only (no signer)". */
export const signedInWith = method => method === "nip07" ? "with a browser extension" : method === "nip46" ? "with a bunker (NIP-46)" : "read-only (no signer)"

export function loadSession(storage = localStorage) {
  try {
    const s = JSON.parse(storage.getItem(KEY) ?? "null")
    return s && PUBKEY.test(s.pubkey) ? s : null
  } catch {
    return null
  }
}

/** Makes `s` the active account, and remembers it among this browser's accounts. */
export function saveSession(s, storage = localStorage) {
  rememberAccount(s, storage)
  storage.setItem(KEY, JSON.stringify(s))
}

/** Signs the active account out of this browser. It leaves the account list too: sign-out deletes its data here. */
export function clearSession(storage = localStorage) {
  const active = loadSession(storage)
  if (active) forgetAccount(active.pubkey, storage)
  storage.removeItem(KEY)
}

/** Every account this browser remembers, in the order they were added. A session from before the list is one. */
export function loadAccounts(storage = localStorage) {
  let list = []
  try { list = JSON.parse(storage.getItem(ACCOUNTS) ?? "[]") } catch {}
  if (!Array.isArray(list)) list = []
  list = list.filter(valid)
  const active = loadSession(storage)
  if (valid(active) && !list.some(a => a.pubkey === active.pubkey)) list.push(active)
  return list
}

/** Adds an account, or replaces the saved one with the same pubkey (a bunker connected again). Doesn't switch to it. */
export function rememberAccount(s, storage = localStorage) {
  if (!valid(s)) throw new Error("not an account")
  const list = loadAccounts(storage)
  const at = list.findIndex(a => a.pubkey === s.pubkey)
  if (at >= 0 && s.method === "readonly" && list[at].method !== "readonly") return // never downgrade a saved signer
  if (at >= 0) list[at] = s
  else list.push(s)
  storage.setItem(ACCOUNTS, JSON.stringify(list))
}

/** Drops an account from the list -> the accounts left. Never the active one's session: clearSession does that. */
export function forgetAccount(pubkey, storage = localStorage) {
  const list = loadAccounts(storage).filter(a => a.pubkey !== pubkey)
  if (list.length) storage.setItem(ACCOUNTS, JSON.stringify(list))
  else storage.removeItem(ACCOUNTS)
  return list
}
