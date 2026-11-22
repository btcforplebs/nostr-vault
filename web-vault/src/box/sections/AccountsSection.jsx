// Settings › Accounts in box mode: the accounts this box holds (One Vault addendum A.3), for the box's first account
// only. Each shows its state (first / signed in / watch-only); Add an account makes a one-time code the new account
// types after signing in with its own signer; Remove takes an account off the box, its notes and files stay.
// Any other account sees nothing here, and isn't asked to sign for it: the list is only asked for when the page's check
// (box-vault.js boxAccount) says this is the first account (Tron L1). Without a check (tests), it asks, and a 403 hides it.
import { useEffect, useMemo, useState } from "preact/hooks"
import { accountsApi, STATE_LABEL } from "../api-accounts.js"
import { boxAccount } from "../box-vault.js"
import { Part, Row } from "./Parts.jsx"
import { shortNpub } from "../format.js"
if (import.meta.env) import("../box.css")

/** `api`: an accountsApi; built from the signer when not given (tests pass one over a mock). `account`: the page's
 *  boxAccountCheck (boxAccount() when not given; null = none, so the list is asked for and a 403 hides it). */
export function AccountsSection({ ctx, api: given, account: givenAccount }) {
  const api = useMemo(() => given ?? accountsApi({ signer: ctx.signer }), [given, ctx.signer])
  const account = givenAccount !== undefined ? givenAccount : boxAccount()
  const [who, setWho] = useState(account ? account.state : "first")
  useEffect(() => { if (!account) return; setWho(account.state); return account.subscribe(s => setWho(s.state)) }, [account])
  const [state, setState] = useState(null) // { value: accounts } | { error } | { hidden }
  const load = () => api.list().then(value => setState({ value }), e => setState(e?.status === 403 ? { hidden: true } : { error: String(e?.message ?? e) }))
  useEffect(() => { if (who === "first") load() }, [api, who])
  if (who !== "first" || state?.hidden) return null
  return (
    <div class="box-screen box-accounts">
      <Part title="Accounts on this box" state={state}>
        {state?.value && <Accounts api={api} accounts={state.value} reload={load} />}
      </Part>
    </div>
  )
}

const day = sec => Number.isFinite(sec) && sec > 0 ? new Date(sec * 1000).toLocaleDateString() : ""
const time = sec => Number.isFinite(sec) ? new Date(sec * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : ""
/** XXXXXXXXXXXX -> XXXX-XXXX-XXXX, easier to read off one screen and type on another (the box ignores the dashes). */
const grouped = code => String(code ?? "").replace(/[-\s]/g, "").replace(/(.{4})(?=.)/g, "$1-")

function Accounts({ api, accounts, reload }) {
  const [code, setCode] = useState(null) // { code, expiresAt }
  const [busy, setBusy] = useState("")
  const [msg, setMsg] = useState(null)
  const act = (label, fn) => async () => {
    setBusy(label); setMsg(null)
    try { await fn() } catch (e) { setMsg({ ok: false, text: String(e?.message ?? e) }) }
    setBusy("")
  }
  const makeCode = act("code", async () => setCode(await api.code()))
  return (
    <div class="settings-rows">
      {accounts.map(a => <AccountLine key={a.npub} account={a} api={api} busy={busy} act={act} setMsg={setMsg} reload={reload} />)}
      {code
        ? <div class="box-form">
            <Row label="One-time code" value={grouped(code.code)} copy={grouped(code.code)} />
            <p class="muted small">On the new account's device, open this box's web address, sign in with that account's own signer (extension, bunker or the Nostr Vault app), and enter this code. It works once{code.expiresAt ? `, until ${time(code.expiresAt)}` : ""}. Never share a secret key (nsec): the box doesn't need one.</p>
            <div class="box-buttons">
              <button type="button" disabled={!!busy} onClick={makeCode}>New code</button>
              <button type="button" class="primary" onClick={() => { setCode(null); reload() }}>Done</button>
            </div>
          </div>
        : <button type="button" class="settings-row box-action" disabled={!!busy} aria-busy={busy === "code" || undefined} onClick={makeCode}>{busy === "code" ? "Asking the box…" : "Add an account"}</button>}
      <p class="muted small box-pad">Every account on this box and every device paired with it can read all of them: they are all yours, as on a Mac. Only the first account runs the box.</p>
      {msg && <p class={`small box-pad ${msg.ok ? "muted" : "error"}`} role={msg.ok ? "status" : "alert"}>{msg.text}</p>}
    </div>
  )
}

function AccountLine({ account: a, api, busy, act, setMsg, reload }) {
  const [confirm, setConfirm] = useState(false)
  const name = a.name?.trim() || shortNpub(a.npub)
  const remove = act(`remove:${a.npub}`, async () => {
    await api.remove(a.npub)
    setMsg({ ok: true, text: `${name} is off this box. Its notes and files stay; adding it again shows them again.` })
    setConfirm(false)
    reload()
  })
  const removing = busy === `remove:${a.npub}`
  return (
    <>
      <div class="settings-row box-row">
        <span class="settings-title">{name}<span class="muted small box-sub">{[a.name?.trim() && shortNpub(a.npub), day(a.added) && `added ${day(a.added)}`].filter(Boolean).join(" · ")}</span></span>
        <span class={`box-value ${a.state === "first" || a.state === "signedIn" ? "good" : ""}`}>{STATE_LABEL[a.state] ?? a.state}</span>
        {a.state !== "first" && !confirm && <button type="button" class="small danger" disabled={!!busy} onClick={() => setConfirm(true)}>Remove</button>}
      </div>
      {confirm && <div class="box-form">
        <p class="muted small">Take {name} off this box? It can't read the box any more, and the box restarts its relay (a few seconds). Its notes and files stay on the box.</p>
        <div class="box-buttons">
          <button type="button" disabled={!!busy} onClick={() => setConfirm(false)}>Cancel</button>
          <button type="button" class="danger" disabled={!!busy} aria-busy={removing || undefined} onClick={remove}>{removing ? "Removing…" : "Remove from box"}</button>
        </div>
      </div>}
    </>
  )
}
