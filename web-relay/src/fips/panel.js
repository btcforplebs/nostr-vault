// FIPS section of the page: owner pairing, start/stop, and status (seed link, owner path, streams).
import { parseOwners } from "./owners.js"
import { RELAY_SERVICE_PORT } from "./tcp-server.js"
import { startFipsRelay, workerRelayStore } from "./node.js"

const OWNERS_ITEM = "fips-owners"
const $ = id => document.getElementById(id)

export function mountFipsPanel({ relay, log, onInsertHook }) {
  let owners = new Set()
  let running
  try {
    owners = parseOwners(localStorage.getItem(OWNERS_ITEM) ?? "")
  } catch {}

  // Pairing link: nostrvault.app/relay/#owner=npub1...  (a fragment never reaches the server)
  const frag = new URLSearchParams(location.hash.slice(1)).get("owner")
  if (frag) {
    try {
      owners = parseOwners(frag)
      localStorage.setItem(OWNERS_ITEM, [...owners].join(" "))
      log("fips-owner-paired", { owners: owners.size })
    } catch (e) {
      log("fips-owner-error", { err: String(e) })
    }
    history.replaceState(null, "", location.pathname)
  }
  $("fipsOwners").value = [...owners].join("\n")

  const render = s => {
    const seeds = [...(s?.seeds ?? new Map())].map(([u, st]) => `${u.replace("wss://", "")}: ${st}`).join(", ") || "none"
    const paths = [...(s?.owners ?? new Map())].map(([k, o]) => `${k.slice(0, 8)}… ${o.transport === "webrtc" ? "DIRECT (webrtc)" : "via " + o.transport} ${o.state}`).join("; ")
    const sessions = [...(s?.sessions ?? new Map())].map(([k, st]) => `${k.slice(0, 8)}… ${st}`).join("; ")
    const sv = s?.server ?? {}
    $("fipsStatus").textContent = running
      ? [`relay ${s.npub}`, `port ${RELAY_SERVICE_PORT}`, `seed: ${seeds}`, `owner session: ${sessions || "none"}`, `owner path: ${paths || "relayed via seed (no direct link)"}`,
         `streams open ${sv.open ?? 0}, accepted ${sv.accepted ?? 0}, stranger datagrams dropped ${sv.rejectedDatagrams ?? 0}`,
         `last REQ ${sv.lastReqAt ? new Date(sv.lastReqAt).toISOString() : "never"}`, s.errors ? `errors ${s.errors}: ${s.lastError}` : ""].filter(Boolean).join("\n")
      : owners.size ? "FIPS off" : "FIPS off: add your vault's npub first"
    const seedUp = [...(s?.seeds?.values() ?? [])].includes("connected")
    $("sfips").textContent = running ? `FIPS ${seedUp ? "seed up" : "seed DOWN"} · streams ${sv.open ?? 0}` : ""
  }

  $("fipsSave").onclick = () => {
    try {
      owners = parseOwners($("fipsOwners").value)
      localStorage.setItem(OWNERS_ITEM, [...owners].join(" "))
      log("fips-owners-saved", { owners: owners.size })
      render(running?.status)
    } catch (e) {
      $("fipsStatus").textContent = String(e)
    }
  }
  $("fipsStart").onclick = async () => {
    if (running) {
      await running.stop()
      running = undefined
      $("fipsStart").textContent = "Start FIPS"
      log("fips-stop")
      return render()
    }
    if (!owners.size) return render()
    try {
      running = await startFipsRelay({ store: workerRelayStore(relay), getOwners: () => owners, onStatus: render })
      onInsertHook(ev => running?.server.notify(ev))
      $("fipsStart").textContent = "Stop FIPS"
      log("fips-start", { npub: running.status.npub })
    } catch (e) {
      log("fips-error", { err: String(e) })
      $("fipsStatus").textContent = "FIPS failed to start: " + e
    }
  }
  render()
}
