// Who Can Reach You (Settings and the Vault Dashboard's Vault settings): the FIPS panel from web-relay (pairing,
// start/stop, seed and owner status), then the account. The relay's status, counts and storage are on the Vault
// Dashboard (VaultDashboard.jsx). The panel finds its elements by id, so this screen stays mounted.
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { signedInWith } from "../session.js"
import { bytesToHex } from "nostr-tools/utils"
import { mountFipsPanel } from "../../../web-relay/src/fips/panel.js"
import { loadRelayIdentity } from "../../../web-relay/src/fips/node.js"
import { fipsStorage } from "../haven/vault.js"
import { resetBrowser } from "./SettingsScreen.jsx"

export function RelayScreen({ ctx, log }) {
  const { vault, session } = ctx
  const [address, setAddress] = useState("")
  const [copied, setCopied] = useState(false)
  useEffect(() => { mountFipsPanel({ haven: vault.haven, owners: vault.owners, log, account: session.pubkey, storage: fipsStorage() }) }, [])
  // The relay's mesh address is the npub of its own FIPS key (made once, kept in this browser), never the user's key.
  // The FIPS card shows only mesh addresses, never the account: FIPS is not tied to who is signed in.
  // The site has no server: this address over FIPS is the only way to reach the relay.
  useEffect(() => { loadRelayIdentity(fipsStorage()).then(id => setAddress(npubEncode(bytesToHex(id.xOnlyPubkey)))) }, [])
  const copy = async () => {
    await navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }
  return (
    <main class="screen">
      <header class="screen-head"><h2>Who Can Reach You</h2></header>
      <section class="card">
        <h3>FIPS</h3>
        <p class="muted small">NIP-01 on port 7447, only for the vaults listed below. FIPS uses this relay's own mesh key, not your Nostr account.</p>
        <div class="k">This relay's mesh address</div>
        <pre class="fips-address">{address || "…"}</pre>
        <div class="row"><button onClick={copy} disabled={!address}>{copied ? "Copied" : "Copy address"}</button></div>
        <div class="k">Who can reach this relay</div>
        <p class="muted small">Add each vault's mesh address, from Mesh settings in Nostr Vault. It's the vault's own FIPS key, not your account. Then start FIPS, and the vault connects to this relay's mesh address on port 7447.</p>
        <textarea id="fipsOwners" rows={2} placeholder="Vault mesh address (one per line)" />
        <div class="row"><button id="fipsSave">Save vaults</button><button id="fipsStart" class="primary">Start FIPS</button></div>
        <pre id="fipsStatus" />
        <span id="sfips" hidden />
      </section>
      <section class="card">
        <h3>Account</h3>
        <div class="muted small">Signed in as {npubEncode(session.pubkey).slice(0, 20)}… {signedInWith(session.method)}.{session.method === "local" ? " Signing out deletes that key here too, so save it first (Settings › Your Secret Key)." : " Your secret key isn't stored here."} Signing out deletes this browser's copy of your relay, its keys and paired vaults.</div>
        <button onClick={() => resetBrowser(ctx)}>Sign out</button>
      </section>
    </main>
  )
}
