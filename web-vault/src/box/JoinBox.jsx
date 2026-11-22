// Joining a box (One Vault W7): shown in Settings' This Box group when the box doesn't hold the signed-in account yet, or
// holds it watch-only. The account types a one-time code from the box's first account (Settings › Accounts there) and
// its signer signs the join request: the code proves the first account let it in, the signature that it holds the key.
// A secret key is never asked for, and one typed here is refused before anything is sent.
import { useState } from "preact/hooks"
if (import.meta.env) import("./box.css")

const SAYS = {
  none: "This box doesn't hold this account yet, so its Vault here stays empty. Ask the box's owner for a code: on their account, Settings › Accounts › Add an account.",
  watchOnly: "This box keeps this account's notes and files, but shows nothing private until the account signs in to it. Ask the box's owner for a code: on their account, Settings › Accounts › Add an account.",
}
const looksLikeNsec = s => /^(nostr:)?nsec1/i.test(s.trim())
/** A code is 12 letters and digits; dashes and spaces are ignored (the box strips them too). Anything else, such as a
 *  64-hex secret key, is refused here and never sent (Tron L3). */
const asCode = s => { const c = s.replace(/[-\s]/g, "").toUpperCase(); return /^[A-Z0-9]{12}$/.test(c) ? c : null }

/** `account`: the page's boxAccountCheck (box-vault.js); `state`: its current state. `reload`: after a join, the page
 *  opens again on the box's new lists (location.reload; a stub in tests). */
export function JoinBox({ account, state, reload = () => globalThis.location?.reload() }) {
  const [code, setCode] = useState("")
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const join = async e => {
    e?.preventDefault?.()
    if (looksLikeNsec(code)) { setMsg({ ok: false, text: "That is a secret key (nsec). Never paste it anywhere: the box only needs the code." }); setCode(""); return }
    if (!code.trim()) return
    const c = asCode(code)
    if (!c) { setMsg({ ok: false, text: "A code is 12 letters and digits, like ABCD-EFGH-JKMN. Never paste a key here." }); if (code.replace(/[-\s]/g, "").length > 12) setCode(""); return }
    setBusy(true); setMsg(null)
    try {
      const r = await account.join(c)
      setMsg({ ok: true, text: r.already ? "This account is already signed in to the box." : "You're on this box now. It restarts its relay for you (a few seconds), then this page opens again." })
      setTimeout(reload, r.already ? 0 : 4000)
    } catch (err) { setMsg({ ok: false, text: String(err?.message ?? err) }); setBusy(false) }
  }
  return (
    <form class="box-form join-box" onSubmit={join}>
      {!msg?.ok && <p class="small">{SAYS[state] ?? SAYS.none}</p>}
      <label class="small" for="join-box-code">Code from the box's owner</label>
      <input id="join-box-code" autocomplete="off" autocapitalize="characters" spellcheck={false} placeholder="XXXX-XXXX-XXXX" value={code} disabled={busy}
        onInput={e => setCode(e.currentTarget.value)} />
      <p class="muted small">Your signer asks to sign once: that proves you hold this account's key. The box never sees the key.</p>
      <div class="box-buttons"><button type="submit" class="primary" disabled={busy || !code.trim()} aria-busy={busy || undefined}>{busy ? "Joining…" : "Join this box"}</button></div>
      {msg && <p class={`small ${msg.ok ? "muted" : "error"}`} role={msg.ok ? "status" : "alert"}>{msg.text}</p>}
    </form>
  )
}
