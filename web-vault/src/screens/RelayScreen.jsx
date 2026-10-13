// Today's relay page as one screen of the app: Haven's status, then the FIPS panel from web-relay (pairing,
// start/stop, seed and owner status). The panel finds its elements by id, so this screen stays mounted.
import { useEffect, useRef, useState } from "preact/hooks"
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
  // This screen mounts at boot, before the follows arrive from the network; the timer reads the current list.
  const follows = useRef(ctx.account.follows)
  follows.current = ctx.account.follows

  useEffect(() => { mountFipsPanel({ haven: vault.haven, owners: vault.owners, log, account: session.pubkey }) }, [])
  // The relay's mesh address is the npub of its own FIPS key (made once, kept in this browser), never the user's key.
  // The FIPS card shows only mesh addresses, never the account: FIPS is not tied to who is signed in.
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
        // Only follows: the thread view also caches other people's notes in /feed.
        follows.current.length ? vault.feed.count({ kinds: [1, 6], authors: follows.current }).catch(() => "?") : 0,
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
        <div class="muted small">storage {storage.persisted ? "persistent" : "may be cleared by the browser"} · started in {vault.loadMs + vault.startMs} ms</div>
      </section>
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
        <div class="muted small">Signed in as {npubEncode(session.pubkey).slice(0, 20)}… with {session.method === "nip07" ? "a browser extension" : "a bunker (NIP-46)"}. Your secret key isn't stored here. Signing out deletes this browser's copy of your relay, its keys and paired vaults.</div>
        <button onClick={ctx.signOut}>Sign out</button>
      </section>
    </main>
  )
}
