// FIPS section of the page: vault pairing by mesh address, start/stop, status (seed link, vault path, streams), and
// showing a photo straight from a paired vault.
import { parseOwners, saveOwners, savePhotoVaults } from "./owners.js"
import { RELAY_SERVICE_PORT } from "./tcp-server.js"
import { startFipsRelay } from "./node.js"
import { startPhotoReader } from "./photo-reader.js"
import { parseBlobRef } from "./blob-get.js"
import { npubEncode } from "nostr-tools/nip19"

const $ = id => document.getElementById(id)

/**
 * @param haven   Haven's started entry point, or undefined when it isn't running (no owner yet, or it failed)
 * @param owners  Set<x-only hex> of the vaults' mesh keys
 * @param photoVaults Set<x-only hex> of vaults' blob nodes (photo addresses): read from, never written by
 * @param account the signed-in user's pubkey, if any: refused as a mesh address
 * @param storage the page's storage (src/page-storage.js): paired vaults and the relay's FIPS key
 */
export function mountFipsPanel({ haven, owners, photoVaults = new Set(), log, account, storage }) {
  let running
  $("fipsOwners").value = [...owners].join("\n")
  $("fipsPhotoVaults").value = [...photoVaults].map(npubEncode).join("\n")

  // No owner + Haven to serve, but photo addresses to read: start the photo-only reader instead of the relay.
  const photoOnly = () => !(owners.size && haven) && photoVaults.size > 0
  const render = s => {
    const seeds = [...(s?.seeds ?? new Map())].map(([u, st]) => `${u.replace("wss://", "")}: ${st}`).join(", ") || "none"
    const paths = [...(s?.owners ?? new Map())].map(([k, o]) => `${k.slice(0, 8)}… ${o.transport === "webrtc" ? "DIRECT (webrtc)" : "via " + o.transport} ${o.state}`).join("; ")
    const sessions = [...(s?.sessions ?? new Map())].map(([k, st]) => `${k.slice(0, 8)}… ${st}`).join("; ")
    const sv = s?.server ?? {}
    $("fipsStatus").textContent = running?.status.photoOnly
      ? [`photos only, throwaway key ${s.npub}`, `seed: ${seeds}`, `reads from your photo addresses only (${photoVaults.size})`,
         `photos read ${s.blobs?.fetched ?? 0} (${s.blobs?.bytes ?? 0} bytes), failed ${s.blobs?.failed ?? 0}${s.blobs?.lastError ? ": " + s.blobs.lastError : ""}`, s.errors ? `errors ${s.errors}: ${s.lastError}` : ""].filter(Boolean).join("\n")
      : running
      ? [`mesh address ${s.npub}`, `port ${RELAY_SERVICE_PORT}`, `seed: ${seeds}`, `vault session: ${sessions || "none"}`, `vault path: ${paths || "relayed via seed (no direct link)"}`,
         `streams open ${sv.open ?? 0}, accepted ${sv.accepted ?? 0}, stranger datagrams dropped ${sv.rejectedDatagrams ?? 0}`,
         `last request from a vault ${sv.lastInAt ? new Date(sv.lastInAt).toISOString() : "never"}`,
         `photos read ${s.blobs?.fetched ?? 0} (${s.blobs?.bytes ?? 0} bytes), failed ${s.blobs?.failed ?? 0}${s.blobs?.lastError ? ": " + s.blobs.lastError : ""}`, s.errors ? `errors ${s.errors}: ${s.lastError}` : ""].filter(Boolean).join("\n")
      : photoOnly() ? "FIPS off. Start reads photos from your photo addresses only (no relay, a new key each time)."
      : !owners.size ? "FIPS off: add a vault's mesh address first"
      : !haven ? "FIPS off: Haven is not running"
      : "FIPS off"
    const seedUp = [...(s?.seeds?.values() ?? [])].includes("connected")
    $("sfips").textContent = running ? `FIPS ${seedUp ? "seed up" : "seed DOWN"} · ${running.status.photoOnly ? "photos only" : `streams ${sv.open ?? 0}`}` : ""
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
  // Read on each photo, so no restart: swap the set's contents in place.
  $("fipsPhotoSave").onclick = () => {
    try {
      const next = parseOwners($("fipsPhotoVaults").value, { account })
      photoVaults.clear()
      for (const k of next) photoVaults.add(k)
      savePhotoVaults(photoVaults, storage)
      log("fips-photo-vaults-saved", { vaults: photoVaults.size })
      $("blobStatus").textContent = `${photoVaults.size} photo address${photoVaults.size === 1 ? "" : "es"} saved`
      if (!running) render()
    } catch (e) {
      $("blobStatus").textContent = String(e)
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
    const photosOnly = photoOnly()
    if (!photosOnly && (!owners.size || !haven)) return render()
    try {
      running = photosOnly
        ? await startPhotoReader({ getPhotoVaults: () => photoVaults, onStatus: render })
        : await startFipsRelay({ haven, getOwners: () => owners, getPhotoVaults: () => photoVaults, storage, onStatus: render })
      $("fipsStart").textContent = "Stop FIPS"
      log("fips-start", { npub: running.status.npub, photoOnly: photosOnly })
    } catch (e) {
      log("fips-error", { err: String(e) })
      $("fipsStatus").textContent = "FIPS failed to start: " + e
    }
  }
  // A photo by hash from a paired vault. A .fips link names the vault (an owner or a photo address); a bare hash
  // tries each photo address, then each owner, in turn.
  let shown
  $("blobGet").onclick = async () => {
    const say = t => ($("blobStatus").textContent = t)
    if (!running) return say("Start FIPS first: the photo comes over its session to your vault.")
    let ref
    try {
      ref = parseBlobRef($("blobRef").value)
    } catch (e) {
      return say(String(e.message ?? e))
    }
    // The photo-only reader never asks an owner: a stranger's link must not reach a vault's main npub.
    const readable = running.status.photoOnly ? photoVaults : new Set([...photoVaults, ...owners])
    const vaults = ref.vault ? [ref.vault] : [...readable]
    if (ref.vault && !readable.has(ref.vault)) return say(`${npubEncode(ref.vault)} is not one of your ${running.status.photoOnly ? "photo addresses" : "paired vaults"}. Add it above as a photo address first.`)
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
