// nostrvault.app/relay/ and nostrvault.app/vault/ are one origin, so they share one localStorage (and one IndexedDB).
// Each page keeps its keys under its own prefix, so neither page's sign-out or reset reaches the other's: the
// FIPS code (src/fips) is shared by both pages and takes the page's storage, never localStorage itself.
export const RELAY_NS = "nv-relay:"
export const VAULT_NS = "nv-vault:"

/** `storage` seen through a prefix: getItem("fips-owners") reads `${ns}fips-owners`. */
export function pageStorage(storage, ns) {
  return {
    ns,
    getItem: k => storage.getItem(ns + k),
    setItem: (k, v) => storage.setItem(ns + k, v),
    removeItem: k => storage.removeItem(ns + k),
  }
}

// Before the prefixes, the relay page kept these unprefixed. They are the relay's (its FIPS key and paired vaults
// above all: a new key is a new mesh address, and every vault would have to re-pair).
const LEGACY_RELAY_KEYS = ["fips-relay-key", "fips-owners", "log", "hb", "sk", "seq", "saver", "gen"]

/** Moves the relay page's unprefixed keys under RELAY_NS, once. A key already moved is never overwritten. */
export function migrateRelayKeys(storage) {
  for (const k of LEGACY_RELAY_KEYS) {
    const v = storage.getItem(k)
    if (v === null) continue
    if (storage.getItem(RELAY_NS + k) === null) storage.setItem(RELAY_NS + k, v)
    storage.removeItem(k)
  }
}
