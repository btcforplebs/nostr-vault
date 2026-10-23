// Guest view: a shared post's link (nostrvault.app/thread/<nevent>, handed to /vault/#/thread/<id> by the thread page)
// opens in the web app for someone who isn't signed in. No key, nothing signed, nothing kept: the stores are in
// memory (memory-vault.js), no session is saved, and every action asks them to sign in. Pure: no DOM.
import { memoryVault } from "./memory-vault.js"
import { DEFAULT_RELAYS, BROADCAST_RELAYS, uniq } from "../net/pool.js"

const HEX = /^[0-9a-f]{64}$/

/** Where a guest reads from: the relays the thread page reads (web-vault/thread-page/fetch.js READ_RELAYS). */
export const GUEST_RELAYS = uniq([...DEFAULT_RELAYS, ...BROADCAST_RELAYS])

/** The post a guest address opens: "#/thread/<id>" (the phone's form) or "#/<list>?note=<id>" (the desktop's,
 *  routes.js deskRedirect). -> the 64-hex id, or null for any other address. */
export function guestTarget(hash = "") {
  const h = String(hash).replace(/^#\/?/, "")
  const i = h.indexOf("?")
  const path = i < 0 ? h : h.slice(0, i)
  const params = new URLSearchParams(i < 0 ? "" : h.slice(i + 1))
  const [route, arg = ""] = path.split("/")
  if (route === "thread") return HEX.test(arg) ? arg : null
  const note = params.get("note")
  return note && HEX.test(note) ? note : null
}

/** The person a guest address opens: "#/profile/<pubkey>" (from the welcome screen's search, or a note's author).
 *  -> the 64-hex pubkey, or null. */
export function guestPerson(hash = "") {
  const [route, arg = ""] = String(hash).replace(/^#\/?/, "").split("?")[0].split("/")
  return route === "profile" && HEX.test(arg) ? arg : null
}

/** A link's relay hints ("?r=<wss url>", up to 3), as the thread page passes them: public wss:// hosts only, since
 *  the link chose them and this browser dials them. Read from the address the page opened with. */
export function guestRelays(hash = "") {
  const i = String(hash).indexOf("?")
  const hints = i < 0 ? [] : new URLSearchParams(hash.slice(i + 1)).getAll("r")
  const ok = []
  for (const r of hints) {
    let u
    try { u = new URL(r) } catch { continue }
    const host = u.hostname.toLowerCase()
    if (u.protocol !== "wss:" || u.username || u.password || !host.includes(".") || host.endsWith(".local") || /^[\d.]+$/.test(host) || host.startsWith("[")) continue
    ok.push(u.href.replace(/\/$/, ""))
    if (ok.length === 3) break
  }
  return uniq([...ok, ...GUEST_RELAYS])
}

export const GUEST_ONLY = "Sign in to like, reply, repost or zap. Looking around needs no account."

/** Read-only, as signer/readonly.js, but nobody's account: every action throws GUEST_ONLY. */
export const guestSigner = () => ({ method: "guest", readOnly: true, signEvent: async () => { throw new Error(GUEST_ONLY) }, close() {} })

/** The app's ctx for a guest: in-memory stores, no pubkey, follows nobody, reads `relays`. */
export function guestContext(relays = GUEST_RELAYS) {
  return {
    guest: true,
    vault: memoryVault(),
    session: { method: "guest", pubkey: "" },
    signer: guestSigner(),
    account: { relays: { read: relays, write: [] }, follows: [], contacts: null, profileEvent: null, loaded: true },
    signOut: () => {},
    reloadAccount: () => {},
  }
}
