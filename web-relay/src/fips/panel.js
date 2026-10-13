// FIPS section of the page: vault pairing by mesh address, start/stop, and status (seed link, vault path, streams).
import { parseOwners, saveOwners } from "./owners.js"
import { RELAY_SERVICE_PORT } from "./tcp-server.js"
import { startFipsRelay } from "./node.js"

const $ = id => document.getElementById(id)

/**
 * @param haven   Haven's started entry point, or undefined when it isn't running (no owner yet, or it failed)
 * @param owners  Set<x-only hex> of the vaults' mesh keys
 * @param account the signed-in user's pubkey, if any: refused as a mesh address
 */
export function mountFipsPanel({ haven, owners, log, account }) {
  let running
  $("fipsOwners").value = [...owners].join("\n")

  const render = s => {
    const seeds = [...(s?.seeds ?? new Map())].map(([u, st]) => `${u.replace("wss://", "")}: ${st}`).join(", ") || "none"
    const paths = [...(s?.owners ?? new Map())].map(([k, o]) => `${k.slice(0, 8)}… ${o.transport === "webrtc" ? "DIRECT (webrtc)" : "via " + o.transport} ${o.state}`).join("; ")
    const sessions = [...(s?.sessions ?? new Map())].map(([k, st]) => `${k.slice(0, 8)}… ${st}`).join("; ")
    const sv = s?.server ?? {}
    $("fipsStatus").textContent = running
      ? [`mesh address ${s.npub}`, `port ${RELAY_SERVICE_PORT}`, `seed: ${seeds}`, `vault session: ${sessions || "none"}`, `vault path: ${paths || "relayed via seed (no direct link)"}`,
         `streams open ${sv.open ?? 0}, accepted ${sv.accepted ?? 0}, stranger datagrams dropped ${sv.rejectedDatagrams ?? 0}`,
         `last request from a vault ${sv.lastInAt ? new Date(sv.lastInAt).toISOString() : "never"}`, s.errors ? `errors ${s.errors}: ${s.lastError}` : ""].filter(Boolean).join("\n")
      : !owners.size ? "FIPS off: add a vault's mesh address first"
      : !haven ? "FIPS off: Haven is not running"
      : "FIPS off"
    const seedUp = [...(s?.seeds?.values() ?? [])].includes("connected")
    $("sfips").textContent = running ? `FIPS ${seedUp ? "seed up" : "seed DOWN"} · streams ${sv.open ?? 0}` : ""
  }

  // Haven takes its owner at start, so a changed owner set means a restart: reload the page.
  $("fipsSave").onclick = () => {
    try {
      const next = parseOwners($("fipsOwners").value, { account })
      saveOwners(next)
      log("fips-owners-saved", { owners: next.size })
      const same = next.size === owners.size && [...next].every(k => owners.has(k))
      if (!same) location.reload()
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
    if (!owners.size || !haven) return render()
    try {
      running = await startFipsRelay({ haven, getOwners: () => owners, onStatus: render })
      $("fipsStart").textContent = "Stop FIPS"
      log("fips-start", { npub: running.status.npub })
    } catch (e) {
      log("fips-error", { err: String(e) })
      $("fipsStatus").textContent = "FIPS failed to start: " + e
    }
  }
  render()
}
