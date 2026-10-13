// Who is signed in, and how: { pubkey, method: "nip07" | "nip46", bunker?, clientSk? }. Never the user's secret key.
const KEY = "nv-session"

export function loadSession(storage = localStorage) {
  try {
    const s = JSON.parse(storage.getItem(KEY) ?? "null")
    return s && /^[0-9a-f]{64}$/.test(s.pubkey) ? s : null
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
