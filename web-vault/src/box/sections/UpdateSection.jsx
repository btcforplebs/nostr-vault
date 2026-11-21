// Box screen, Update: the running version and Check for update, or the app store that updates the box. `state`: the
// status call's { value } | { error }.
import { useState } from "preact/hooks"
import { Part, Row } from "./Parts.jsx"

export function UpdateSection({ api, state }) {
  const status = state?.value
  return (
    <Part title="Update" state={state}>
      {status && <Update api={api} version={status.version} store={STORES[status.update_via]} />}
    </Part>
  )
}

// linux/README.md: installing the newer package is the update (audit K2: nothing on the box runs one yet).
const RELEASES = "https://github.com/btcforplebs/nostr-vault/releases"
// NV_UPDATE_VIA: a store installed the box and updates it; the box answers update with { managed, via }.
const STORES = { startos: "the StartOS Marketplace", umbrel: "the Umbrel App Store" }

function Update({ api, version, store: given }) {
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const run = async () => {
    setBusy(true); setMsg(null)
    try {
      const r = await api.update()
      const store = r.managed ? STORES[r.via] ?? given : null
      setMsg({ ok: true, text: r.managed ? `Update Nostr Vault from ${store ?? "the app store that installed it"}.` : !r.started || r.via === "file" ? `Updates are manual for now. On the box, install the newer package from ${RELEASES}` : r.to ? `Updating ${r.from || version} to ${r.to}.` : "Update started." })
    } catch (e) { setMsg({ ok: false, text: String(e?.message ?? e) }) }
    setBusy(false)
  }
  return (
    <div class="settings-rows">
      <Row label="Running" value={version ? `Version ${version}` : "—"} />
      {given ? <p class="muted small box-pad">Updates come from {given}: update Nostr Vault there.</p>
        : <>
          <button type="button" class="settings-row box-action" disabled={busy} aria-busy={busy || undefined} onClick={run}>{busy ? "Asking the box…" : "Check for update and install"}</button>
          <p class="muted small box-pad">Updates are manual for now: install the newer package on the box. There is no automatic way back to the old version yet.</p>
        </>}
      {msg && <p class={`small box-pad ${msg.ok ? "muted" : "error"}`} role={msg.ok ? "status" : "alert"}>{msg.text}</p>}
    </div>
  )
}
