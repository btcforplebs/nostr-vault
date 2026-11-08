// The /relay/ page's keep-awake: the screensaver holds a screen wake lock so the phone or laptop doesn't sleep the
// vault. Whether it is on is kept in the page's storage ("saver"), so a reload, crash or tab discard brings it back,
// and a lock the browser dropped when the tab was hidden is taken again when it is visible.
export const SAVER_ITEM = "saver"

/**
 * @param storage  the page's storage (src/page-storage.js)
 * @param wakeLock navigator.wakeLock (may be missing)
 * @param doc      document: its visibilitychange re-takes the lock
 * @param onChange ({ saverOn, held }) => void, after every change
 */
export function createKeepAwake({ storage, wakeLock = globalThis.navigator?.wakeLock, doc = globalThis.document, onChange = () => {}, log = () => {} }) {
  let lock = null, saverOn = false, taking = false
  const changed = () => onChange({ saverOn, held: !!lock })
  async function take() {
    if (lock || taking || !saverOn) return changed()
    if (!wakeLock) { log("wakelock-error", { err: "no wake lock API" }); return changed() }
    taking = true
    try {
      const l = await wakeLock.request("screen")
      log("wakelock-acquired")
      l.addEventListener("release", () => { log("wakelock-released"); if (lock === l) lock = null; changed() })
      if (saverOn) lock = l
      else l.release()
    } catch (e) { log("wakelock-error", { err: String(e) }) }
    finally { taking = false }
    changed()
  }
  doc?.addEventListener("visibilitychange", () => { if (doc.visibilityState === "visible") take() })
  return {
    get saverOn() { return saverOn },
    get held() { return !!lock },
    /** The person at the page turned the screensaver on. */
    start() { saverOn = true; storage.setItem(SAVER_ITEM, "1"); return take() },
    stop() { saverOn = false; storage.setItem(SAVER_ITEM, "0"); const l = lock; lock = null; changed(); return l?.release() },
    /** At page load: the screensaver comes back on if it was on when the page went away. */
    restore() { if (storage.getItem(SAVER_ITEM) !== "1") return changed(); saverOn = true; return take() },
  }
}

/** Asks the browser to keep this origin's storage (the vault's IndexedDB) under storage pressure, once it isn't already. */
export async function ensurePersisted(storageManager = globalThis.navigator?.storage) {
  if (!storageManager?.persist) return false
  try {
    if (await storageManager.persisted?.()) return true
    return await storageManager.persist()
  } catch { return false }
}
