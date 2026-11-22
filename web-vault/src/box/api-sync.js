// Box API, Sync area (One Vault E3/W3): the box catching up from the owner's other vaults. Shapes
// (haven-go/internal/box/routes_sync.go, sync.go):
//   GET  sync        -> { busy, running?, round, lastRound?, nextRound?, everySeconds, devices: [Device] }
//                       devices and running are filled for the first account only; others get []
//   Device: { peer: npub, token, syncedAt?, last?: { kind: "first"|"sync", started, finished?, error?, got, sent, files,
//             gone }, reach?: why nv-mesh couldn't reach it, needs?: "first_copy" }
//   POST sync/now    { device? } -> 202; 429 { retryAfter } when asked again within a minute; any signed-in account
//   POST sync/first  { device } -> 202; 409 when the box already has a copy (use Sync now) or one is running;
//                    first account only
// Its own signed caller, as api-accounts.js: the box's own words are shown, and a 429 says how long to wait.
import { nip98Header } from "./api.js"
import { boxApiBase } from "./mode.js"

/** `signer`: the signed-in account's ({ signEvent }); `fetchImpl`: fetch (a mock in tests). */
export function syncApi({ signer, base = boxApiBase(), fetchImpl = (...a) => fetch(...a) }) {
  const call = async (method, name, payload) => {
    if (!signer?.signEvent || signer.readOnly) throw new Error("Sign in with your account's signer to use the box.")
    const url = `${base}/${name}`
    const body = payload ? JSON.stringify(payload) : undefined
    const headers = { Authorization: await nip98Header(signer, url, method, payload) }
    if (body) headers["Content-Type"] = "application/json"
    const res = await fetchImpl(url, { method, headers, body })
    const text = await res.text()
    let data = null
    try { data = text ? JSON.parse(text) : null } catch {}
    if (!res.ok) {
      const said = data?.message || data?.error
      const e = new Error(res.status === 429 ? `Asked just now. Try again in ${waitWords(data?.retryAfter)}.`
        : said ? said[0].toUpperCase() + said.slice(1) : `The box answered ${res.status}`)
      e.status = res.status
      throw e
    }
    return data ?? {}
  }
  return {
    state: () => call("GET", "sync"),
    now: (device = "") => call("POST", "sync/now", device ? { device } : {}),
    first: device => call("POST", "sync/first", { device }),
  }
}

const waitWords = s => (Number.isFinite(s) && s > 0 ? (s < 90 ? `${Math.ceil(s)} s` : `${Math.ceil(s / 60)} min`) : "a minute")

/** A copy's contract code (copyErrorCode) in plain words. */
export const SYNC_ERROR = {
  auth_refused: "That vault no longer accepts this box. Copy from it again.",
  unreachable: "Couldn't reach it over the mesh.",
  needs_space: "Not enough space on this box.",
  partial: "Partly copied. The next catch-up finishes it.",
  wrong_owner: "That vault holds none of this box's accounts.",
  busy: "That vault is busy with another copy.",
  cancelled: "Stopped.",
}
export const syncErrorWords = code => SYNC_ERROR[code] ?? `Stopped (${code}).`
