// A pretend box for the screens before the real one exists (dev builds and tests only): answers the box API's shapes
// (api.js) from memory. Made-up values: no real address, key or host.
const GB = 1e9
const npub = c => `npub1${c.repeat(58)}`

/** `store`: "startos" or "umbrel" for a box a store installed (NV_UPDATE_VIA, empty NV_MOVE_ROOT). */
export function mockBox({ now = () => Date.now(), store } = {}) {
  const state = {
    version: "1.0.0", started: now() - 3 * 86400e3 - 4 * 3600e3,
    path: "/data", used: 18.4 * GB, total: 512 * GB,
    devices: [
      { npub: npub("q"), name: "Phone", role: "phone", approved: true, lastSeen: Math.floor(now() / 1000) - 120 },
      { npub: npub("p"), name: "", role: "mac", approved: true, lastSeen: Math.floor(now() / 1000) - 7200 },
    ],
  }
  const answer = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
  return async (url, { method = "GET", body, headers = {} } = {}) => {
    if (!String(headers.Authorization ?? "").startsWith("Nostr ")) return answer(401, { error: "owner only" })
    const name = new URL(url).pathname.replace(/^\/api\/box\//, "")
    if (method === "GET" && name === "status") return answer(200, {
      version: state.version, uptime: Math.floor((now() - state.started) / 1000),
      mem: { used: 0.9 * GB, total: 4 * GB }, disk: { used: state.used, total: state.total },
      mesh: { up: true, npub: npub("z"), peers: 3 },
      ...(store && { update_via: store, move_off: true }),
    })
    if (method === "GET" && name === "storage") return answer(200, { path: state.path, used: state.used, free: state.total - state.used, total: state.total, ...(store && { move_off: true }) })
    if (method === "GET" && name === "devices") return answer(200, { box: { npub: npub("z"), name: "Box" }, devices: state.devices })
    if (method === "POST" && name === "update") return answer(200, store ? { started: false, managed: true, via: store, from: state.version } : { started: false, manual: true, via: "manual", from: state.version })
    if (method === "POST" && name === "move") {
      if (store) return answer(403, { error: "moving the vault is off on this box: its store manages the disk" })
      const { path } = JSON.parse(body ?? "{}")
      if (!/^\/\S+/.test(path ?? "")) return answer(400, { message: "Give a full folder path, like /mnt/disk/nostr-vault." })
      state.path = path
      return answer(200, { ok: true, path, message: `Moving your vault to ${path}. The box restarts when it's done.` })
    }
    return answer(404, { error: "not found" })
  }
}
