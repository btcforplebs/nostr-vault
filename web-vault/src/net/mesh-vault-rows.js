// The rows of Media Servers › Your Vaults on the Mesh (MeshVaultRows.jsx). Pure, for the tests.
import { npubEncode } from "nostr-tools/nip19"
import { meshVaults } from "./fips-ref.js"

const ROLE = { mac: "Desktop vault", homeVault: "Mobile vault", phone: "Phone", browser: "Browser vault" }

/** `[{ url, npub, title }]` for the list's mesh entries, in order: named as pairing named them, else by role (or
 *  "Mesh vault") and the end of the address, as Your devices does. `paired`: pairedDevices() rows. */
export function meshVaultRows(urls, paired = []) {
  const byHex = new Map(paired.map(p => [p.hex, p]))
  return urls.flatMap(url => {
    const [hex] = meshVaults({ tags: [["server", url]] })
    if (!hex) return []
    const npub = npubEncode(hex)
    const p = byHex.get(hex)
    const tail = `${npub.slice(0, 9)}…${npub.slice(-4)}`
    return [{ url, npub, title: p?.name || `${ROLE[p?.role] ?? "Mesh vault"} ${tail}` }]
  })
}
