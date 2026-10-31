// A pretend box for the screens before the real one exists (dev builds and tests only): answers the box API's shapes
// (api.js) from memory. Made-up values: no real address, key or host.
const GB = 1e9
const npub = c => `npub1${c.repeat(58)}`

export function mockBox({ now = () => Date.now() } = {}) {
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
    })
    if (method === "GET" && name === "storage") return answer(200, { path: state.path, used: state.used, free: state.total - state.used, total: state.total })
    if (method === "GET" && name === "devices") return answer(200, { box: { npub: npub("z"), name: "Box" }, devices: state.devices })
    if (method === "POST" && name === "update") return answer(200, { started: true, from: state.version, to: "1.0.1", rollback: `Version ${state.version} is kept. If 1.0.1 doesn't start, the box goes back to it.` })
    if (method === "POST" && name === "move") {
      const { path } = JSON.parse(body ?? "{}")
      if (!/^\/\S+/.test(path ?? "")) return answer(400, { message: "Give a full folder path, like /mnt/disk/nostr-vault." })
      state.path = path
      return answer(200, { ok: true, path, message: `Moving your vault to ${path}. The box restarts when it's done.` })
    }
    return answer(404, { error: "not found" })
  }
}
