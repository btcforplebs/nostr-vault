// The box's owner-only API (/api/box/, NIP-98: each request carries a kind 27235 event signed by the owner, NV_OWNER).
// Shapes the box screens read (shared contract, nostr-vault-linux):
//   GET  status   -> { version, uptime: seconds, mem: { used, total }, disk: { used, total }, mesh: { up, npub, peers } }
//   GET  storage  -> { path, used, free, total }                       bytes
//   GET  devices  -> { box: { npub, name }, devices: [{ npub, name, role, approved, lastSeen }] }
//                    havend: the owner's 10063 has no names or seen times, so name is "" and lastSeen is left out
//   POST update   -> { started, from, to, rollback }                   rollback: what the box keeps to go back to
//                    havend: to/rollback only when the container side knows them
//   POST move     { path } -> { ok, path, message }
// A missing field reads as unknown, never as 0.
import { getToken } from "nostr-tools/nip98"
import { boxApiBase } from "./mode.js"

/** The NIP-98 Authorization header ("Nostr <base64 event>") for `method` `url`. `payload`: the object sent as the JSON
 *  body; its sha256 goes in the payload tag (nostr-tools hashes JSON.stringify(payload), the exact body sent). */
export const nip98Header = (signer, url, method, payload) => getToken(url, method, e => signer.signEvent(e), true, payload)

/** A client for the box API. `fetchImpl`: fetch (a mock in tests and the screenshot harness). */
export function boxApi({ signer, base = boxApiBase(), fetchImpl = (...a) => fetch(...a) }) {
  const call = async (method, name, payload) => {
    if (!signer?.signEvent || signer.readOnly) throw new Error("Sign in as the box's owner to manage it.")
    const url = `${base}/${name}`
    const body = payload ? JSON.stringify(payload) : undefined
    const headers = { Authorization: await nip98Header(signer, url, method, payload) }
    if (body) headers["Content-Type"] = "application/json"
    const res = await fetchImpl(url, { method, headers, body })
    const text = await res.text()
    let data = null
    try { data = text ? JSON.parse(text) : null } catch {}
    if (res.status === 401 || res.status === 403) throw new Error("Only the box's owner can do this. Sign in with the account the box was set up for.")
    if (!res.ok) throw new Error(data?.message || data?.error || `The box answered ${res.status}`)
    return data ?? {}
  }
  return {
    status: () => call("GET", "status"),
    storage: () => call("GET", "storage"),
    devices: () => call("GET", "devices"),
    update: () => call("POST", "update", {}),
    move: path => call("POST", "move", { path }),
  }
}
