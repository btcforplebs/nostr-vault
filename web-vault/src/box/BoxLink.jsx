// Settings' first row in box mode: the box's own screens (#/box), where the browser relay's status card would be. An
// account the box doesn't hold yet (or holds watch-only) gets the join form (JoinBox.jsx) instead, from the page's
// "does this box hold me" check (box-vault.js boxAccount).
import { useEffect, useState } from "preact/hooks"
import { boxAccount } from "./box-vault.js"
import { JoinBox } from "./JoinBox.jsx"
export { BOX } from "./mode.js"

/** `account`: a boxAccountCheck (the running vault's when not given; tests pass one). */
export function BoxLink({ account: given, reload } = {}) {
  const account = given ?? boxAccount()
  const [state, setState] = useState(account?.state)
  const [error, setError] = useState(account?.error ?? null)
  useEffect(() => { if (!account) return; setState(account.state); setError(account.error); return account.subscribe(s => { setState(s.state); setError(s.error) }) }, [account])
  const [retrying, setRetrying] = useState(false)
  const retry = () => { setRetrying(true); account.check().finally(() => setRetrying(false)) }
  // Once shown, the join form stays until the page reloads, so its "you're on this box now" is seen.
  const outside = s => s === "none" || s === "watchOnly"
  const [join, setJoin] = useState(() => outside(account?.state))
  useEffect(() => { if (outside(state)) setJoin(true) }, [state])
  return (
    <section class="settings-group">
      <div class="section-label">This Box</div>
      <div class="settings-rows">
        {join ? <JoinBox account={account} state={state} reload={reload} />
          : error ? <div class="box-form box-check-failed">
              {/* The check failed (a full strangers cache 429, a 401 from clock skew, a dismissed signer): say so, or an
                  account the box doesn't hold meets a silently empty Vault (Tron L2). */}
              <p class="small error" role="alert">Couldn't ask this box whether it holds this account: {error}</p>
              <div class="box-buttons">
                <button type="button" disabled={retrying} aria-busy={retrying || undefined} onClick={retry}>{retrying ? "Asking…" : "Retry"}</button>
                <a class="settings-row" href="#/box"><span class="settings-title">Box screens</span><span aria-hidden="true">›</span></a>
              </div>
            </div>
          : <a class="settings-row" href="#/box">
              <span class="settings-title">Status, storage, mesh, devices and updates</span>
              <span aria-hidden="true">›</span>
            </a>}
      </div>
    </section>
  )
}
