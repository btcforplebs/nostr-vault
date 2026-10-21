// Where a note photo lives on the FIPS mesh, from what a note and its author publish. Pure: no network, no FIPS
// packages, so the note parsers can use it. The loader is fips-media.js.
import { decode } from "nostr-tools/nip19"

const NPUB = "npub1[02-9ac-hj-np-z]+"
const LINK = new RegExp(`^http://(${NPUB})\\.fips/([0-9a-f]{64})(\\.[a-z0-9]{1,8})?$`)
const MESH_SERVER = new RegExp(`^fipsmesh://(${NPUB})/?$`)

const hexOf = npub => { try { const d = decode(npub); return d.type === "npub" ? d.data : undefined } catch { return undefined } }

/** { vault: x-only hex, sha256 } for a NIP-F1 photo link `http://<npub>.fips/<sha256>[.ext]`, else undefined. */
export function fipsRef(url) {
  const m = LINK.exec(String(url ?? "").trim().toLowerCase())
  const vault = m && hexOf(m[1])
  return vault ? { vault, sha256: m[2] } : undefined
}

/** The mesh vaults in a kind 10063: its `fipsmesh://<npub>/` server entries, as x-only hex, in order, once each. */
export function meshVaults(ev) {
  const out = []
  for (const t of ev?.tags ?? []) {
    const m = t?.[0] === "server" && MESH_SERVER.exec(String(t[1] ?? "").trim().toLowerCase())
    const k = m && hexOf(m[1])
    if (k && !out.includes(k)) out.push(k)
  }
  return out
}
