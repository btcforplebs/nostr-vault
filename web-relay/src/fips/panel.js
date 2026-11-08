// FIPS section of the page: vault pairing by mesh address, start/stop, status (seed link, vault path, streams), and
// showing a photo straight from a paired vault.
import { parseOwners, saveOwners } from "./owners.js"
import { mountAccountProof } from "./account-panel.js"
import { RELAY_SERVICE_PORT } from "./tcp-server.js"
import { startFipsRelay } from "./node.js"
import { parseBlobRef } from "./blob-get.js"
import { npubEncode } from "nostr-tools/nip19"

const $ = id => document.getElementById(id)
// Set by Stop mesh, cleared by Start mesh: the page doesn't rejoin by itself after the person at it turned the mesh off.
export const MESH_OFF_ITEM = "fips-mesh-off"

/**
 * @param haven   Haven's started entry point, or undefined when it isn't running (no owner yet, or it failed)
 * @param owners  Set<x-only hex> of the vaults' mesh keys
 * @param account the signed-in user's pubkey, if any: refused as a mesh address
 * @param storage the page's storage (src/page-storage.js): paired vaults and the relay's FIPS key
 * @param bind    the relay page's own key: the owner's account proof names it (owner-proof.js)
 * @param autoStart the /relay/ page: join the mesh by itself when vaults are saved, and again on resume/pageshow, unless
 *                the person at the browser pressed Stop mesh (kept in storage). The web app's Relay screen leaves it off.
 * @param win     where resume/pageshow/visibilitychange arrive (tests pass a stand-in)
 * @param startRelay startFipsRelay, or a stand-in in tests
 */
export function mountFipsPanel({ haven, owners, log, account, storage, bind, autoStart = false, win = globalThis.window, startRelay = startFipsRelay }) {
  let running, starting
  $("fipsOwners").value = [...owners].join("\n")
  // The web app's Relay screen mounts this panel without the account box (its account is the signed-in one).
  if ($("fipsAccount")) mountAccountProof({ storage, bind, log })
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
      saveOwners(next, storage)
      log("fips-owners-saved", { owners: next.size })
      const same = next.size === owners.size && [...next].every(k => owners.has(k))
      if (!same) location.reload()
    } catch (e) {
      $("fipsStatus").textContent = String(e)
    }
  }
  // Joining the mesh. `auto` is a rejoin nobody clicked for: it never runs after Stop mesh, and a failure only logs.
  const start = async ({ auto = false } = {}) => {
    if (running || starting) return
    if (!owners.size || !haven) return render()
    starting = true
    try {
      running = await startRelay({ haven, getOwners: () => owners, storage, onStatus: render })
      $("fipsStart").textContent = "Stop mesh"
      log(auto ? "fips-autostart" : "fips-start", { npub: running.status.npub })
    } catch (e) {
      log("fips-error", { err: String(e), auto })
      $("fipsStatus").textContent = "The mesh failed to start: " + e
    } finally {
      starting = false
    }
  }
  $("fipsStart").onclick = async () => {
    if (starting) return
    if (running) {
      const r = running
      running = undefined
      if (autoStart) storage.setItem(MESH_OFF_ITEM, "1")
      await r.stop()
      $("fipsStart").textContent = "Start mesh"
      log("fips-stop")
      return render()
    }
    if (autoStart) storage.removeItem(MESH_OFF_ITEM)
    await start()
  }
  // A reload, crash or tab discard loads the page again: rejoin with the saved vaults. A frozen tab that comes back
  // (resume, a back/forward-cache pageshow, or turning visible) rejoins too if the mesh isn't up by then.
  const rejoin = () => { if (storage.getItem(MESH_OFF_ITEM) !== "1") start({ auto: true }) }
  if (autoStart && win) {
    win.addEventListener("pageshow", rejoin)
    win.document?.addEventListener("resume", rejoin)
    win.document?.addEventListener("visibilitychange", () => { if (win.document.visibilityState === "visible") rejoin() })
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
  if (autoStart) rejoin()
}
