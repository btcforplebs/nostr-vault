// Who is signed in, and how: { pubkey, method: "nip07" | "nip46", bunker?, clientSk? }. Never the user's secret key.
const KEY = "nv-session"
const PUBKEY = /^[0-9a-f]{64}$/

/** A signer's pubkey must be 64 lowercase hex characters before it goes into the session. */
export function checkedPubkey(pk) {
  if (typeof pk === "string" && PUBKEY.test(pk)) return pk
  throw new Error("Your signer sent back something that isn't a public key. Try again, or use another signer.")
}

export function loadSession(storage = localStorage) {
  try {
    const s = JSON.parse(storage.getItem(KEY) ?? "null")
    return s && PUBKEY.test(s.pubkey) ? s : null
  } catch {
    return null
  }
}

export function saveSession(s, storage = localStorage) {
  storage.setItem(KEY, JSON.stringify(s))
}

export function clearSession(storage = localStorage) {
  storage.removeItem(KEY)
}
