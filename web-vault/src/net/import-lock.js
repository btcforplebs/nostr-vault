// One import at a time in this browser (Tidy 20): Import notes from the Dashboard or Settings, a backup restore from
// Settings or setup, in this tab or another. Two at once cost bandwidth and showed two progress lines for one vault.
// navigator.locks reaches across tabs of the same origin; a browser without it gets a lock for this tab only.
export const IMPORT_LOCK = "nv-import"
export const IMPORT_BUSY = "An import or restore is already running in this browser, in this tab or another. Try again once it has finished."

let local = false

/** Runs `fn` holding the import lock, or throws IMPORT_BUSY at once when another import holds it. `locks` is for tests. */
export async function withImportLock(fn, { locks = globalThis.navigator?.locks } = {}) {
  if (typeof locks?.request !== "function") {
    if (local) throw new Error(IMPORT_BUSY)
    local = true
    try { return await fn() } finally { local = false }
  }
  return locks.request(IMPORT_LOCK, { ifAvailable: true }, async lock => {
    if (!lock) throw new Error(IMPORT_BUSY)
    return fn()
  })
}
