// FIPS section of the page: vault pairing by mesh address, start/stop, status (seed link, vault path, streams), and
// showing a photo straight from a paired vault.
import { parseOwners, saveOwners, loadOwnerAccount, saveOwnerAccount } from "./owners.js"
import { RELAY_SERVICE_PORT } from "./tcp-server.js"
import { startFipsRelay } from "./node.js"
import { parseBlobRef } from "./blob-get.js"
import { npubEncode } from "nostr-tools/nip19"

const $ = id => document.getElementById(id)

/**
 * @param haven   Haven's started entry point, or undefined when it isn't running (no owner yet, or it failed)
 * @param owners  Set<x-only hex> of the vaults' mesh keys
 * @param account the signed-in user's pubkey, if any: refused as a mesh address
 * @param storage the page's storage (src/page-storage.js): paired vaults and the relay's FIPS key
 */
export function mountFipsPanel({ haven, owners, log, account, storage }) {
  let running
  $("fipsOwners").value = [...owners].join("\n")
  // The web app's Relay screen mounts this panel without the account box.
  const accountUi = !!$("fipsAccount")
  const savedAccount = accountUi ? loadOwnerAccount(storage) : undefined
  if (accountUi) $("fipsAccount").value = savedAccount ? npubEncode(savedAccount) : ""
  // Show photo is this page's own: the web app's Relay screen mounts the panel without it, and its Save/Start must
  // still work there.
  const photoUi = !!$("blobGet")
  const render = s => {
    const seeds = [...(s?.seeds ?? new Map())].map(([u, st]) => `${u.replace("wss://", "")}: ${st}`).join(", ") || "none"
    const paths = [...(s?.owners ?? new Map())].map(([k, o]) => `${k.slice(0, 8)}… ${o.transport === "webrtc" ? "DIRECT (webrtc)" : "via " + o.transport} ${o.state}`).join("; ")
    const sessions = [...(s?.sessions ?? new Map())].map(([k, st]) => `${k.slice(0, 8)}… ${st}`).join("; ")
    const sv = s?.server ?? {}
    $("fipsStatus").textContent = running
      ? [`mesh address ${s.npub}`, `port ${RELAY_SERVICE_PORT}`, `seed: ${seeds}`, `vault session: ${sessions || "none"}`, `vault path: ${paths || "relayed via seed (no direct link)"}`,
         `streams open ${sv.open ?? 0}, accepted ${sv.accepted ?? 0}, stranger datagrams dropped ${sv.rejectedDatagrams ?? 0}`,
         `public photo door (port 80): open ${s.door?.open ?? 0}, accepted ${s.door?.accepted ?? 0}`,
         `last request from a vault ${sv.lastInAt ? new Date(sv.lastInAt).toISOString() : "never"}`,
         `photos read ${s.blobs?.fetched ?? 0} (${s.blobs?.bytes ?? 0} bytes), failed ${s.blobs?.failed ?? 0}${s.blobs?.lastError ? ": " + s.blobs.lastError : ""}`, s.errors ? `errors ${s.errors}: ${s.lastError}` : ""].filter(Boolean).join("\n")
      : !owners.size ? "Mesh off: add a vault's mesh address first"
      : !haven ? "Mesh off: the vault is not running"
      : "Mesh off"
    const seedUp = [...(s?.seeds?.values() ?? [])].includes("connected")
    $("sfips").textContent = running ? `FIPS ${seedUp ? "seed up" : "seed DOWN"} · streams ${sv.open ?? 0}` : ""
  }

  // Haven takes its owner at start, so a changed owner set means a restart: reload the page.
  $("fipsSave").onclick = () => {
    try {
      const next = parseOwners($("fipsOwners").value, { account })
      const nextAccount = accountUi ? saveOwnerAccount($("fipsAccount").value, storage) : savedAccount
      saveOwners(next, storage)
      log("fips-owners-saved", { owners: next.size, account: !!nextAccount })
      const same = next.size === owners.size && [...next].every(k => owners.has(k)) && nextAccount === savedAccount
      if (!same) location.reload()
    } catch (e) {
      $("fipsStatus").textContent = String(e)
    }
  }
  $("fipsStart").onclick = async () => {
    if (running) {
      await running.stop()
      running = undefined
      $("fipsStart").textContent = "Start mesh"
      log("fips-stop")
      return render()
    }
    if (!owners.size || !haven) return render()
    try {
      running = await startFipsRelay({ haven, getOwners: () => owners, storage, onStatus: render })
      $("fipsStart").textContent = "Stop mesh"
      log("fips-start", { npub: running.status.npub })
    } catch (e) {
      log("fips-error", { err: String(e) })
      $("fipsStatus").textContent = "The mesh failed to start: " + e
    }
  }
  // A photo by hash from a paired vault. A .fips link names the vault; a bare hash tries each paired vault in turn.
  let shown
  if (photoUi) $("blobGet").onclick = async () => {
    const say = t => ($("blobStatus").textContent = t)
    if (!running) return say("Start the mesh first: the photo comes from your vault over the mesh.")
    let ref
    try {
      ref = parseBlobRef($("blobRef").value)
    } catch (e) {
      return say(String(e.message ?? e))
    }
    const vaults = ref.vault ? [ref.vault] : [...owners]
    if (ref.vault && !owners.has(ref.vault)) return say(`${npubEncode(ref.vault)} is not one of your paired vaults. Add its mesh address above first.`)
    const t0 = Date.now()
    const errors = []
    for (const vault of vaults) {
      const who = npubEncode(vault).slice(0, 16) + "…"
      try {
        say(`asking ${who} for ${ref.sha256.slice(0, 12)}…`)
        const { bytes, type } = await running.getBlob(vault, ref.sha256, { onProgress: n => say(`from ${who}: ${n} bytes…`) })
        if (shown) URL.revokeObjectURL(shown)
        // `type` is already limited to raster images and video (blob-get.js SAFE_TYPES): this URL has the page's origin.
        shown = URL.createObjectURL(new Blob([bytes], { type }))
        const el = document.createElement(type.startsWith("video/") ? "video" : "img")
        el.src = shown
        el.style.cssText = "max-width:100%;max-height:70vh;border-radius:8px"
        if (el.tagName === "VIDEO") el.controls = true
        $("blobView").replaceChildren(el)
        log("fips-blob", { vault: vault.slice(0, 12), bytes: bytes.length, ms: Date.now() - t0 })
        return say(`${bytes.length} bytes from ${who} in ${((Date.now() - t0) / 1000).toFixed(1)}s, sha256 matches, ${type}`)
      } catch (e) {
        errors.push(`${who}: ${e.message ?? e}`)
      }
    }
    log("fips-blob-error", { errors })
    say(errors.join("\n") || "no paired vault")
  }
  render()
}
