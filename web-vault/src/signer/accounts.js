// The accounts this browser remembers (session.js keeps the list): switching to one, and removing one that isn't
// signed in. Signing the active account out is main.jsx's signOut (vault.js forgetThisBrowser).
import { loadSession, saveSession, forgetAccount, checkedPubkey } from "../session.js"
import { storeNames, forgetAccountKeys } from "../haven/vault.js"
import { findExtension } from "./nip07.js"
import { bunkerSigner } from "./nip46.js"

/**
 * Before switching to an extension account: the extension must be signed in as that account now, or every post would
 * be signed by someone else. Throws a message the screen shows.
 */
export async function checkExtensionAccount(account, find = findExtension) {
  const ext = await find()
  if (!ext) throw new Error("No Nostr extension found in this browser. This account signs with one.")
  if (checkedPubkey(await ext.getPublicKey()) !== account.pubkey) throw new Error("Your extension is signed in as a different account. Switch accounts in the extension, then try again.")
}

/**
 * Switch: stop this account's Haven, close its signer, make `account` active, and reload into it. Writing the session
 * is also what makes this page's other tabs stop and reload (vault.js onSignedOutElsewhere).
 */
export async function switchAccount({ account, vault, signer, storage = localStorage, reload = () => location.replace(location.pathname) }) {
  if (account.method === "nip07") await checkExtensionAccount(account)
  await vault?.haven.stop().catch(() => {})
  signer?.close?.()
  saveSession(account, storage)
  reload()
}

/**
 * Remove an account that isn't the active one: ask its bunker to drop this browser's grant, delete its relay stores
 * here, and forget it. -> { failed: store names not deleted, revoked: true | false | null (no bunker) }
 * Its stores aren't open (only the active account's Haven runs), unless another tab is mid-switch.
 */
export async function removeAccount({ account, pool, storage = localStorage, idb = indexedDB, waitMs = 5000, signerFor = bunkerSigner, session = globalThis.sessionStorage }) {
  if (loadSession(storage)?.pubkey === account.pubkey) throw new Error("That's the account you're using. Sign out instead.")
  const revoked = account.method === "nip46" ? await signerFor(account, pool, storage).revoke() : null
  forgetAccount(account.pubkey, storage)
  forgetAccountKeys(account.pubkey, { storage, session })
  const failed = []
  await Promise.all((await storeNames(account.pubkey, idb)).filter(n => n.startsWith(`haven:${account.pubkey}:`)).map(name => new Promise(resolve => {
    const timer = setTimeout(() => { failed.push(name); resolve() }, waitMs)
    const req = idb.deleteDatabase(name)
    req.onsuccess = () => { clearTimeout(timer); resolve() }
    req.onerror = () => { clearTimeout(timer); failed.push(name); resolve() }
  })))
  return { failed: failed.sort(), revoked }
}
