// A localStorage key that belongs to one account: "<base>:<pubkey>" for the account signed in on `storage`, so
// sign-out and removing the account delete it (haven/vault.js accountKeys) and the next account never sees it. The
// key from before, with no account on it, can't be told apart and is dropped once the account's own is in use (bug
// hunt 2026-11-05 #2). With no one signed in (tests, the guest view) it stays the base key.
import { loadSession } from "../session.js"

export function accountKey(base, storage = globalThis.localStorage) {
  let me = null
  try { me = loadSession(storage)?.pubkey ?? null } catch {}
  if (!me) return base
  try { storage?.removeItem(base) } catch {}
  return `${base}:${me}`
}
