// Settings › Media Servers › Your Vaults on the Mesh (iPhone/Mac MeshMediaServersSection): the `fipsmesh://<npub>/`
// entries already on the account's media server list (kind 10063, NIP-F1), each with its device name, a mesh tag
// and Remove. This browser can't reach the mesh to test them, so there's no health line. Adding a vault happens on
// the phone or Mac that links it; Remove here goes out with the rest of the list on Save and publish.
import { pairedDevices } from "../net/pair-devices.js"
import { meshVaultRows } from "../net/mesh-vault-rows.js"

export function MeshVaultRows({ urls, readOnly, busy, onRemove, storage = globalThis.localStorage }) {
  let paired = []
  try { paired = pairedDevices(storage) } catch {}
  const rows = meshVaultRows(urls, paired)
  if (!rows.length) return null
  return (
    <section class="settings-group relay-list">
      <div class="section-label">Your Vaults on the Mesh</div>
      {rows.map(r => (
        <div key={r.url} class="settings-row static relay-edit-row">
          <span class="settings-title" title={r.url}>{r.title}</span>
          <span class="settings-tags">
            <span class="tag">mesh</span>
            {!readOnly && <button type="button" class="small relay-remove" disabled={busy} aria-label={`Remove ${r.title} from my media servers`} onClick={() => onRemove(r.url)}>Remove</button>}
          </span>
        </div>
      ))}
      <p class="settings-note muted small">Listing a vault tells apps that speak the mesh (FIPS) where to load your media. Your media server list is public.</p>
    </section>
  )
}
