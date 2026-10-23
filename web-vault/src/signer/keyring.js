// Seals a bunker session's client key for localStorage. The client key is not the user's key (the bunker holds that,
// and can revoke this one), but it can ask the bunker to sign, so it is never stored as plain hex: it is encrypted with
// AES-GCM under a key that is generated non-extractable and kept in IndexedDB. A copy of localStorage alone (a synced
// profile, a log, a backup of the browser's files) can't use it. Script running in this page can still ask the browser
// to unseal it, as it could ask the bunker to sign: this guards the stored copy, not a compromised page.
const DB = "nv-keyring"
const STORE = "keys"
const WRAP = "wrap"

const b64 = bytes => btoa(String.fromCharCode(...bytes))
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0))

/** The wrapping key's home: IndexedDB in the page; tests pass a Map-backed one. { get(name), add(name, key) }; add
 *  never replaces a key that is already there (it rejects instead). */
export function idbKeyStore(idb = globalThis.indexedDB) {
  const open = () => new Promise((resolve, reject) => {
    const req = idb.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
  const run = (mode, fn) => open().then(db => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode)
    const req = fn(tx.objectStore(STORE))
    tx.oncomplete = () => { db.close(); resolve(req.result) }
    tx.onerror = tx.onabort = () => { db.close(); reject(tx.error) }
  }))
  return {
    get: name => run("readonly", s => s.get(name)),
    add: (name, key) => run("readwrite", s => s.add(key, name)),
  }
}

let defaultStore
const store = ks => ks ?? (defaultStore ??= idbKeyStore())

async function wrappingKey(ks, create) {
  const have = await ks.get(WRAP)
  if (have || !create) return have
  const key = await subtle().generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"])
  // Two tabs signing in at once could both make one: only the first is stored, and both seal with that one.
  await ks.add(WRAP, key).catch(() => {})
  return ks.get(WRAP)
}

/** hex secret -> { iv, ct } (base64), for the session in localStorage. */
export async function seal(hex, ks) {
  subtle()
  const key = await wrappingKey(store(ks), true)
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(hex)))
  return { iv: b64(iv), ct: b64(ct) }
}

export const LOST_KEY = "This browser no longer has the key for your bunker connection (its site data was partly cleared). Sign out of this account (or remove it in Accounts, if it isn't the one you're using), then connect your bunker again."
// crypto.subtle only exists on https pages and localhost. Bunker sign-in needs it to store the connection encrypted, and
// refuses rather than storing it in the clear.
/** Why nothing can be sealed here, for what the user was doing ("Signing in with a bunker", "Creating an account"). */
export const insecure = (doing = "Signing in with a bunker") => `${doing} needs a secure page: open Nostr Vault over https (or on localhost), not plain http.`
export const INSECURE = insecure()
const subtle = (doing) => { if (!globalThis.crypto?.subtle) throw new Error(insecure(doing)); return globalThis.crypto.subtle }
/** Throws insecure(doing) where nothing can be sealed: checked before a sign-in starts, not after the user approves. */
export const assertCanSeal = (doing) => { subtle(doing) }

/** { iv, ct } -> hex secret. Throws LOST_KEY when the wrapping key is gone or doesn't open it. */
export async function unseal(sealed, ks) {
  subtle()
  const key = await wrappingKey(store(ks), false)
  if (!key || !sealed?.iv || !sealed?.ct) throw new Error(LOST_KEY)
  try {
    return new TextDecoder().decode(await subtle().decrypt({ name: "AES-GCM", iv: unb64(sealed.iv) }, key, unb64(sealed.ct)))
  } catch {
    throw new Error(LOST_KEY)
  }
}
