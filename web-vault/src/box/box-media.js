// Vault › Media in box mode (3.3.0 "one Vault", W2): the box's own files come first. The box serves Blossom on the
// page's own origin (haven-go/internal/box/front.go hands /list/, /upload, /mirror and /<sha256> to the vault engine),
// so the box is put at the head of the account's media servers. Media lists it first, and an upload goes to it first,
// as a Mac's Media goes to the Mac. On a LAN the box is plain http, which serverUrl turns down for a note's link
// (https only), so its own links are let through here, for Media only.
// Delete never reaches the box from here: deleteTargets leaves out every home-network server and asks any other
// whether it is one of your vaults (blossom-gallery.js), so the box keeps its copy, as a Mac or phone vault does.
import { BOX } from "./mode.js"
import { serverUrl, uploadPhoto } from "../net/upload.js"
import { isHomeNetworkHost, mirrorBlob } from "../net/blossom-gallery.js"

const hostnameOf = url => { try { return new URL(url).hostname } catch { return "" } }
const originOf = url => { try { return new URL(url).origin } catch { return null } }

/** The box's own Blossom server: the page's origin in box mode, else null. `box` and `loc` are for tests. */
export function boxMediaServer({ box = BOX, loc = globalThis.location } = {}) {
  if (!box || !loc?.origin || loc.origin === "null") return null
  return loc.origin
}

/** The media servers Media lists and uploads to: the box first in box mode, then the account's own (kind 10063), each
 *  once. Outside box mode, `servers` as given. */
export function withBox(servers, opts) {
  const own = boxMediaServer(opts)
  return own ? [own, ...(servers ?? []).filter(s => s !== own)] : servers ?? []
}

/** Whether a link a server sent back may be kept: https as anywhere (serverUrl), or one on the box itself. */
export function mediaLinkOk(url, opts) {
  if (serverUrl(url)) return true
  const own = boxMediaServer(opts)
  return !!own && originOf(url) === own
}

/** Upload for Vault › Media: uploadPhoto taking the box's own link too. */
export const uploadMedia = (file, o) => uploadPhoto(file, { ...o, linkOk: url => mediaLinkOk(url) })

/** A link to this file that a server out on the internet can fetch: its own link when that is public, else one of the
 *  public servers that holds it. null when only home-network servers (the box on a LAN) hold it. */
export function publicSource(blob) {
  if (!isHomeNetworkHost(hostnameOf(blob.url))) return blob.url
  const ext = /\.[A-Za-z0-9]{1,10}$/.exec(new URL(blob.url).pathname)?.[0] ?? ""
  const held = (blob.servers ?? []).find(s => !isHomeNetworkHost(hostnameOf(s)))
  return held ? `${held}/${blob.sha256}${ext}` : null
}

/**
 * Copy a file to the servers that don't hold it. A server fetches it itself (BUD-04 mirror) from a link it can reach.
 * A file only the box holds on a LAN has no such link: the browser reads it from the box and uploads the same bytes
 * (raw, so the hash stays) to each public server instead. A home-network server missing it is still asked to mirror.
 * -> [{ server, ok, message }], as mirrorBlob.
 */
export async function copyToServers(blob, servers, { ctx, fetch = globalThis.fetch, upload = uploadPhoto }) {
  const missing = servers.filter(s => !blob.servers.includes(s))
  if (!missing.length) return []
  const from = publicSource(blob)
  if (from) return mirrorBlob(blob, missing, { ctx, fetch, from })
  const home = missing.filter(s => isHomeNetworkHost(hostnameOf(s)))
  const outside = missing.filter(s => !home.includes(s))
  const mirrored = home.length ? mirrorBlob(blob, home, { ctx, fetch }) : Promise.resolve([])
  let file = null, why = ""
  try {
    const res = await fetch(blob.url)
    if (res.ok) file = new File([await res.blob()], blob.sha256, { type: blob.type || res.headers?.get?.("Content-Type") || "application/octet-stream" })
    else why = `couldn't read it from your box (HTTP ${res.status})`
  } catch (e) { why = `couldn't read it from your box: ${e?.message ?? e}` }
  const pushed = []
  for (const server of outside) {
    if (!file) { pushed.push({ server, ok: false, message: why }); continue }
    try {
      const r = await upload(file, { ctx, servers: [server], raw: true, fetch })
      pushed.push(r.sha256 === blob.sha256 ? { server, ok: true, message: "" } : { server, ok: false, message: "didn't confirm the file's hash" })
    } catch (e) { pushed.push({ server, ok: false, message: String(e?.message ?? e).replace(/^No media server took it\. /, "") }) }
  }
  return [...(await mirrored), ...pushed]
}
