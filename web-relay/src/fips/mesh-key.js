// This browser's mesh (FIPS) secret key at rest. It is the device's own key, never the account's, but it is the
// browser's mesh address, so the stored copy is never plain hex: it is AES-GCM sealed under a wrapping key that is
// generated non-extractable and kept in IndexedDB (as web-vault/src/signer/keyring.js does for a bunker session). A
// copy of localStorage alone (a synced profile, a log, a backup of the browser's files) can't use it. Script running
// in this page can still ask the browser to unseal it: this guards the stored copy, not a compromised page.
// No imports: web-vault's first load reads this (net/pair-hello.js) without the FIPS engine.
export const KEY_ITEM = "fips-relay-key"
const HEX64 = /^[0-9a-f]{64}$/
const DB = "nv-mesh-keyring"
const STORE = "keys"
const WRAP = "mesh-wrap"

const toHex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
const fromHex = hex => Uint8Array.from(hex.match(/../g), b => parseInt(b, 16))
const b64 = bytes => btoa(String.fromCharCode(...bytes))
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0))

/** The wrapping key's home: IndexedDB in the page; tests pass a Map-backed one. { get(name), add(name, key) }; add
 *  never replaces a key that is already there (it rejects instead). */
export function idbMeshKeyStore(idb = globalThis.indexedDB) {
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
/** Sealing needs crypto.subtle (https or localhost) and IndexedDB. Without them the key stays plain hex, as before. */
function sealer(ks) {
  const subtle = globalThis.crypto?.subtle
  if (!subtle) return null
  if (ks) return { subtle, ks }
  if (!globalThis.indexedDB) return null
  return { subtle, ks: (defaultStore ??= idbMeshKeyStore()) }
}

async function wrappingKey({ subtle, ks }, create) {
  const have = await ks.get(WRAP)
  if (have || !create) return have
  const key = await subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"])
  // Two tabs at once could both make one: only the first is stored, and both seal with that one.
  await ks.add(WRAP, key).catch(() => {})
  return ks.get(WRAP)
}

async function seal(s, hex) {
  const key = await wrappingKey(s, true)
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = new Uint8Array(await s.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(hex)))
  return JSON.stringify({ v: 1, iv: b64(iv), ct: b64(ct) })
}

/** `hex` sealed, or `hex` itself when there is no sealer or sealing fails (IndexedDB refused: private mode, storage
 *  blocked). A key that stays plain is what the browser had before this; losing the mesh here would be worse. */
async function sealOrPlain(s, hex) {
  if (!s) return hex
  try { return await seal(s, hex) } catch (e) {
    console.warn("mesh key: could not seal, kept plain:", e?.message ?? e)
    return hex
  }
}

const CANT_READ = "this browser's mesh key can't be read"

async function unseal(s, stored) {
  let box
  try { box = JSON.parse(stored) } catch { throw new Error(CANT_READ) }
  if (box?.v !== 1 || typeof box.iv !== "string" || typeof box.ct !== "string") throw new Error(CANT_READ)
  // No wrapping key (site data partly cleared, or no crypto here): an error, never a new key, which would change
  // this browser's mesh address. Signing out of this browser clears both.
  const key = s && await wrappingKey(s, false)
  if (!key) throw new Error(CANT_READ)
  let hex
  try { hex = new TextDecoder().decode(await s.subtle.decrypt({ name: "AES-GCM", iv: unb64(box.iv) }, key, unb64(box.ct))) }
  catch { throw new Error(CANT_READ) }
  if (!HEX64.test(hex)) throw new Error(CANT_READ)
  return hex
}

/**
 * The mesh secret key in `storage` (a page storage, src/page-storage.js), as 32 fresh bytes the caller may zero. Made
 * first when there is none. A plain-hex key from before is sealed in place, the same key, so the address never
 * changes. A stored value that can't be read is an error, never replaced. `ks` is for tests.
 */
export async function loadMeshSecret(storage, { ks } = {}) {
  const s = sealer(ks)
  let stored = storage.getItem(KEY_ITEM)
  if (stored === null || stored === "") {
    const hex = toHex(crypto.getRandomValues(new Uint8Array(32)))
    storage.setItem(KEY_ITEM, await sealOrPlain(s, hex))
    // Another tab may have written its key between the read and the write: read back, so all tabs use one key.
    stored = storage.getItem(KEY_ITEM)
  }
  if (HEX64.test(stored)) {
    // Sealed only once the sealed copy exists, so a failure leaves the plain key, not none.
    const sealed = await sealOrPlain(s, stored)
    if (sealed !== stored) storage.setItem(KEY_ITEM, sealed)
    return fromHex(stored)
  }
  return fromHex(await unseal(s, stored))
}
