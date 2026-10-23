// Settings > Your Secret Key, for an account made in this browser (screens/CreateAccount.jsx): the only other place
// its key can be saved from after the Your Keys step. The nsec shows only after the password opens the ncryptsec
// (signer/local.js revealNsec) and is dropped when the page closes; the ncryptsec can be copied as it is.
import { useState } from "preact/hooks"
import { revealNsec } from "../signer/local.js"
import { KEEP_IT, sevenDayErase } from "../components/StorageNote.jsx"
import { KeyCard } from "../components/KeyCard.jsx"

export function YourKeyPage({ ctx, safari = sevenDayErase() }) {
  const [pw, setPw] = useState("")
  const [nsec, setNsec] = useState("")
  const [err, setErr] = useState("")
  const show = e => {
    e.preventDefault(); setErr("")
    try { setNsec(revealNsec(ctx.session, pw)); setPw("") } catch (e) { setErr(String(e?.message ?? e)) }
  }
  return (
    <>
      <p class="settings-note muted small">This account's secret key was made in this browser. It is the only way into the account: signing out, removing the account or clearing this site's data deletes it here, and nobody can recover it for you. Keep a copy somewhere safe.</p>
      {KEEP_IT[safari] && <p class="onboard-warn box">{KEEP_IT[safari]}</p>}
      {nsec
        ? <>
            <KeyCard title="Secret key" secret caption="Anyone who has it can post as you, so never share it." value={nsec} />
            <button type="button" onClick={() => setNsec("")}>Hide</button>
          </>
        : <form class="card" onSubmit={show}>
            <h3>Show my secret key</h3>
            <input type="text" name="username" autocomplete="username" value="Nostr Vault key" hidden readOnly />
            <label class="field"><span>Password</span>
              <input type="password" value={pw} onInput={e => setPw(e.currentTarget.value)} autocomplete="current-password" required /></label>
            {err && <p class="error small" role="alert">{err}</p>}
            <button type="submit" class="primary" disabled={!pw}>Show</button>
          </form>}
      <KeyCard title="Encrypted secret key" caption="Your secret key locked with your password (NIP-49). Nostr apps that take an ncryptsec open it with the same password." value={ctx.session.ncryptsec} />
    </>
  )
}
