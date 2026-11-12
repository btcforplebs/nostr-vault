// Box › Public on the web: the switch (public-on-web.js). Off by default for a box with no web address; with one, it
// shows whether your relay list names it now. A tap publishes your 10002 and then your 10050 (publishList: refused
// with nothing changed if your relays don't answer or the list changed elsewhere). Shown only in box mode (BoxScreen).
import { useEffect, useState } from "preact/hooks"
import { latestList, publishList } from "../net/list-edit.js"
import { boxRelay, listed, setListed } from "./public-on-web.js"

export function PublicOnWeb({ ctx, relayUrl, lists = { latest: latestList, publish: publishList } }) {
  const relay = boxRelay(relayUrl)
  const [state, setState] = useState(null) // { relays, inbox } latest events, or { error }
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const load = () => Promise.all([lists.latest(ctx, 10002), lists.latest(ctx, 10050)])
    .then(([relays, inbox]) => setState({ relays, inbox }), e => setState({ error: String(e?.message ?? e) }))
  useEffect(() => { if (relay) load() }, [relay])

  if (!relay) return <p class="muted small box-pad">
    This box has no web address, so it's reached only by your own devices over the mesh. To make it public, give it a
    domain and a tunnel (NV_RELAY_URL in the box's .env; see the Linux guide), then come back here.</p>
  if (!state) return <p class="muted small box-pad">Reading your relay list…</p>
  if (state.error) return <p class="error small box-pad" role="alert">{state.error}</p>
  const on = listed(state.relays.event?.tags, "r", relay)

  const set = async next => {
    setBusy(true); setMsg(null)
    try {
      await setListed(ctx, relay, next, state, lists.publish)
      setMsg({ ok: true, text: next ? `Listed: ${relay} is in your relay list and DM inbox.` : "Unlisted: your devices still reach it over the mesh." })
    } catch (e) { setMsg({ ok: false, text: String(e?.message ?? e) }) }
    await load()
    setBusy(false)
  }

  return (
    <div class="settings-rows">
      <label class="settings-row box-row">
        <span class="settings-title">Make this vault public on the web</span>
        <input type="checkbox" role="switch" checked={on} disabled={busy} onChange={e => set(e.currentTarget.checked)} />
      </label>
      <p class="muted small box-pad">{on ? `Listed as ${relay}` : `Off: ${relay} serves, but your lists don't name it.`} The
        tunnel keeps running until you stop it on the box.</p>
      {msg && <p class={`${msg.ok ? "muted" : "error"} small box-pad`} role={msg.ok ? undefined : "alert"}>{msg.text}</p>}
    </div>
  )
}
