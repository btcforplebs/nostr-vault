// Today's relay page as one screen of the app: Haven's status, then the FIPS panel from web-relay (pairing,
// start/stop, seed and owner status). The panel finds its elements by id, so this screen stays mounted.
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { bytesToHex } from "nostr-tools/utils"
import { mountFipsPanel } from "../../../web-relay/src/fips/panel.js"
import { loadRelayIdentity } from "../../../web-relay/src/fips/node.js"

export function RelayScreen({ ctx, log }) {
  const { vault, session } = ctx
  const [counts, setCounts] = useState({})
  const [storage, setStorage] = useState({})
  const [address, setAddress] = useState("")
  const [copied, setCopied] = useState(false)

  useEffect(() => { mountFipsPanel({ haven: vault.haven, owners: vault.owners, log }) }, [])
  // The relay's FIPS address is the npub of its own key (made once, kept in this browser), never the user's key.
  // The site has no server: this address over FIPS is the only way to reach the relay.
  useEffect(() => { loadRelayIdentity().then(id => setAddress(npubEncode(bytesToHex(id.xOnlyPubkey)))) }, [])
  const copy = async () => {
    await navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }
  useEffect(() => {
    const tick = async () => {
      const [own, feed] = await Promise.all([
        vault.outbox.count({ authors: [session.pubkey] }).catch(() => "?"),
        vault.feed.count({ kinds: [1, 6] }).catch(() => "?"),
      ])
      const est = await navigator.storage?.estimate?.()
      setCounts({ own, feed })
      setStorage({ persisted: await navigator.storage?.persisted?.(), usageMB: est ? (est.usage / 1048576).toFixed(1) : "?" })
    }
    tick()
    const t = setInterval(tick, 10_000)
    return () => clearInterval(t)
  }, [])

  return (
    <main class="screen">
      <header class="screen-head"><h2>Relay</h2></header>
      <section class="card">
        <div class="relay-state"><span class="dot on" />Haven running in this browser</div>
        <div class="stats">
          <div><div class="k">your events</div><div class="v">{counts.own ?? "–"}</div></div>
          <div><div class="k">feed cache</div><div class="v">{counts.feed ?? "–"}</div></div>
          <div><div class="k">storage</div><div class="v">{storage.usageMB ?? "–"} MB</div></div>
        </div>
        <div class="muted small">owner {npubEncode(session.pubkey).slice(0, 20)}… · storage {storage.persisted ? "persistent" : "may be cleared by the browser"} · started in {vault.loadMs + vault.startMs} ms</div>
      </section>
      <section class="card">
        <h3>FIPS</h3>
        <p class="muted small">NIP-01 on port 7447, for your paired vaults only.</p>
        <div class="k">Your relay's FIPS address</div>
        <pre class="fips-address">{address || "…"}</pre>
        <div class="row"><button onClick={copy} disabled={!address}>{copied ? "Copied" : "Copy address"}</button></div>
        <p class="muted small">To reach this relay from Nostr Vault, add your vault's npub below and start FIPS. Your vault then connects to this address on port 7447.</p>
        <textarea id="fipsOwners" rows={2} placeholder="Your vault's npub (one per line)" />
        <div class="row"><button id="fipsSave">Save vaults</button><button id="fipsStart" class="primary">Start FIPS</button></div>
        <pre id="fipsStatus" />
        <span id="sfips" hidden />
      </section>
      <section class="card">
        <h3>Account</h3>
        <div class="muted small">Signed in with {session.method === "nip07" ? "a browser extension" : "a bunker (NIP-46)"}. Your secret key isn't stored here.</div>
        <button onClick={ctx.signOut}>Sign out</button>
      </section>
    </main>
  )
}
