// The Vault Dashboard's data in box mode (One Vault W1): the box's own status, storage, devices, contents,
// connections and log, from its API (api.js), each part on its own so a slow or refused call leaves the rest showing.
// Off the box (BOX false) it asks nothing and returns null, so the dashboard reads the browser's vault as before.
import { useEffect, useMemo, useState } from "preact/hooks"
import { BOX } from "./mode.js"
import { boxApi } from "./api.js"

export const BOX_PARTS = ["status", "storage", "devices", "contents", "connections", "logs"]
const POLL_MS = 30_000

/** `on`: box mode (tests pass true); `api`: a boxApi (tests and the harness pass one over a mock).
 *  -> null off the box, else { api, data: { part: { value } | { error } }, load(part), look() } */
export function useBoxDashboard(ctx, { on = BOX, api: given } = {}) {
  const api = useMemo(() => (on ? given ?? boxApi({ signer: ctx.signer }) : null), [on, given, ctx.signer])
  const [data, setData] = useState({})
  const load = part => api[part]().then(value => setData(d => ({ ...d, [part]: { value } })), e => setData(d => ({ ...d, [part]: { error: String(e?.message ?? e) } })))
  const look = () => { for (const p of BOX_PARTS) load(p) }
  useEffect(() => {
    if (!api) return
    look()
    // Status, connections and the log move on their own; the rest is asked again by Try again or after a move.
    const t = setInterval(() => { for (const p of ["status", "connections", "logs"]) load(p) }, POLL_MS)
    return () => clearInterval(t)
  }, [api])
  return api ? { api, data, load, look } : null
}

/** The In your vault numbers from the box's contents answer: { usage, media } in the shape the browser's are. */
export function boxStorage(contents) {
  const c = contents?.value
  if (!c) return { usage: undefined, media: null }
  const s = c.split ?? {}
  return { usage: (s.database ?? 0) + (s.media ?? 0) + (s.other ?? 0), media: c.media ?? null }
}
