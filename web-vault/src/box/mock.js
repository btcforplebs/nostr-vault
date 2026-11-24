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
    if (method === "GET" && name === "contents") return answer(200, {
      vaultDir: state.path, measuredAt: Math.floor(now() / 1000), disk: { used: state.used, free: state.total - state.used, total: state.total },
      split: { database: 2.1 * GB, media: 14.2 * GB, other: 0.3 * GB },
      media: { count: 4210, size: 14.2 * GB, buckets: { image: { count: 3900, size: 6.1 * GB }, video: { count: 260, size: 7.9 * GB }, audio: { count: 40, size: 0.2 * GB }, other: { count: 10, size: 0.001 * GB } } },
    })
    if (method === "GET" && name === "vault-status") return answer(200, { writtenAt: Math.floor(now() / 1000) - 10, status: mockVaultStatus(Math.floor(now() / 1000)) })
    if (method === "GET" && name === "connections") return answer(200, { open: 2, byRoute: { "/": 1, "/private": 1 } })
    if (method === "GET" && name.startsWith("logs")) return answer(200, { last: 3, lines: [
      { seq: 1, at: Math.floor(now() / 1000) - 600, source: "box", text: "box: engine started (pid 41) in /data" },
      { seq: 2, at: Math.floor(now() / 1000) - 300, source: "engine", text: "import: retrying relay.example in 30s" },
      { seq: 3, at: Math.floor(now() / 1000) - 60, source: "engine", text: "blossom: upload failed: disk full" },
    ] })
    // Jobs (api-jobs.js): imports, trust, block list, backups, restart. A job finishes on the next read.
    const job = (kind, jobName) => { state.job = { kind, name: jobName, phase: "stopping", startedAt: Math.floor(now() / 1000) }; return answer(202, state.job) }
    if (method === "GET" && name === "imports") return answer(200, { account: "a".repeat(64), jobs: state.jobs ??= [{ name: "setup", status: "done", stored: 120, unread: [] }, { name: "replies", status: "partial", stored: 40, unread: [{ relay: "wss://relay.example", from: "2025-01-01", to: "2025-02-01", why: "timeout" }] }] })
    if (method === "POST" && (name === "imports/run" || name === "imports/cancel")) {
      const { job: j } = JSON.parse(body ?? "{}")
      const running = state.jobs?.find(x => x.status === "running")
      if (name === "imports/run" && running) return answer(200, { asked: true, answered: true, code: 2, message: "Another job is running; try again when it ends." })
      state.jobs = (state.jobs ?? []).filter(x => x.name !== j).concat({ name: j, status: name === "imports/run" ? "running" : "cancelled", stored: 0, unread: [] })
      return answer(200, { asked: true, answered: true, code: 0, message: name === "imports/run" ? "Started." : "Stopping." })
    }
    if (method === "POST" && name === "trust/refresh") return answer(200, { asked: true, answered: true, code: 0, message: "Rebuilding who can reach you." })
    if (method === "GET" && name === "trust") return answer(200, { trust: { running: false, size: 5120 }, last: { seq: 1, code: 0 } })
    if (method === "GET" && name === "blocklist") return answer(200, { npubs: state.blocklist ??= [] })
    if (method === "POST" && name === "blocklist") { state.blocklist = JSON.parse(body ?? "{}").npubs; return answer(200, { npubs: state.blocklist, blocked: state.blocklist.length, answered: true }) }
    if (method === "GET" && name === "backups") {
      if (state.job && state.job.phase !== "done" && state.job.phase !== "failed") {
        state.job = { ...state.job, phase: "done", finishedAt: Math.floor(now() / 1000) }
        if (state.job.kind === "backup") (state.backups ??= []).unshift({ name: state.job.name, size: 2_400_000, createdAt: state.job.finishedAt })
      }
      return answer(200, { backups: state.backups ??= [{ name: "vault-20261120-030000.zip", size: 2_100_000, createdAt: Math.floor(now() / 1000) - 86400 }], job: state.job ?? null })
    }
    if (method === "POST" && name === "backups/now") return job("backup", `vault-${new Date(now()).toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15)}.zip`)
    if (method === "POST" && name === "backups/restore") return job("restore", JSON.parse(body ?? "{}").name)
    if (method === "POST" && name === "restart") return job("restart")
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

/** A box mid-way through a trust ranking pass, for the Trust ranking card. Made-up numbers. */
export const mockVaultStatus = t => ({
  version: 1, at: t, state: "running", accounts: [{
    account: "a".repeat(64), running: true, ring: 3, ringDone: 411, ringTotal: 1980, listsRead: 37,
    finishedAt: t - 12 * 3600, result: { builtAt: t - 12 * 3600, people: 30640, maxHop: 5, viewBar: 55,
      distantByShown: Array.from({ length: 101 }, (_, s) => (s >= 55 ? 40 : 10)) },
    distantAtBar: 1840, distantFetchAt: t - 14 * 60, distantFetchPeople: 500, distantFetchNew: 34,
    handoffs: [{ device: "b".repeat(64), role: "phone", name: "LogePhone", tookAt: t - 3 * 3600, checkedAt: t - 600 },
      { device: "c".repeat(64), role: "phone", tookAt: t - 26 * 3600, checkedAt: t - 900 }],
  }],
})
