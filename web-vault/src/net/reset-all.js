// Settings › Database & Reset › Reset Everything (iPhone AdvancedSettingsView Factory Reset): every account on this
// browser goes, with its stores, its leftovers and its key if it was kept here; each bunker is asked to drop this
// browser; then this app's own settings and the keyring that sealed bunker connections. /relay/'s keys stay
// (RELAY_NS): it is another page on the same origin.
import { RELAY_NS } from "../../../web-relay/src/page-storage.js"
import { loadAccounts } from "../session.js"
import { removeAccount } from "../signer/accounts.js"
import { forgetThisBrowser } from "../haven/vault.js"

export const RESET_ALL_QUESTION = "Reset everything? This deletes every account on this browser, and the key of any account kept only here, along with all notes, messages, drafts, paired vaults and settings. A key with no backup elsewhere can't be recovered. Your phone's vault is untouched."

/** This app's settings and marks in localStorage: "nv-…" (not /relay/'s "nv-relay:…") and the iPhone-named keys. */
export const isAppKey = k => (k.startsWith("nv-") && !k.startsWith(RELAY_NS)) || /^(post|media|display)\./.test(k)
const KEYRING_DB = "nv-keyring" // signer/keyring.js
const keysOf = store => { const out = []; try { for (let i = 0; i < store.length; i++) { const k = store.key(i); if (k) out.push(k) } } catch {} return out }

/** -> { failed: store names not deleted, revokeFailed: how many bunkers didn't confirm } */
export async function resetEverything({ vault, pubkey, pool, storage = localStorage, idb = indexedDB, session = globalThis.sessionStorage, sw, waitMs = 5000, signerFor }) {
  const failed = []
  let revokeFailed = 0
  for (const account of loadAccounts(storage).filter(a => a.pubkey !== pubkey)) {
    try {
      const r = await removeAccount({ account, pool, storage, idb, session, waitMs, ...(signerFor ? { signerFor } : {}) })
      failed.push(...r.failed)
      if (r.revoked === false) revokeFailed++
    } catch { failed.push(`account ${account.pubkey.slice(0, 8)}`) }
  }
  failed.push(...(await forgetThisBrowser({ vault, pubkey, storage, idb, waitMs, session, ...(sw ? { sw } : {}) })).failed)
  for (const store of [storage, session]) for (const k of keysOf(store)) if (isAppKey(k)) store.removeItem(k)
  await new Promise(resolve => {
    const timer = setTimeout(() => { failed.push(KEYRING_DB); resolve() }, waitMs)
    const req = idb.deleteDatabase(KEYRING_DB)
    req.onsuccess = () => { clearTimeout(timer); resolve() }
    req.onerror = () => { clearTimeout(timer); failed.push(KEYRING_DB); resolve() }
  })
  return { failed: failed.sort(), revokeFailed }
}
