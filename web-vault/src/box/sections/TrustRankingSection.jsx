// Box dashboard, Trust ranking: what the box's trust ranking, distant posts and rank hand-off are doing, from the
// engine's status (GET /api/box/vault-status), the same lines the apps' "Your desktop Vault" shows. `state`: the
// call's { value } | { error }; `names`: hex -> a device's name from GET devices.
import { Part, Row } from "./Parts.jsx"
import * as T from "../vault-status.js"

export function TrustRankingSection({ state, names, now = Date.now() / 1000 }) {
  const value = state?.value
  const s = value?.status
  const a = T.accountOf(s)
  return (
    <Part title="Trust ranking" state={state}>
      {value && !s && <p class="muted small box-pad">The vault hasn't reported its trust ranking yet. It does every 15 seconds once it is up to date.</p>}
      {s && <div class="settings-rows">
        <Row label={T.headline(s)} value={T.updated(value.writtenAt, now) ?? ""} />
        <div class="box-pad box-lines">
          {[T.pausedHint(s), T.progress(a), a && T.finished(a, now), T.distant(a), a && T.distantFetch(a, now)].filter(Boolean).map(line =>
            <p key={line} class="muted small">{line}</p>)}
        </div>
        {(a?.handoffs ?? []).map(h => <Row key={h.device} label={T.handoffName(h, names)} value={T.handoff(h, now)} />)}
      </div>}
    </Part>
  )
}
