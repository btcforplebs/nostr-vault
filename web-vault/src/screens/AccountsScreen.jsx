// Accounts and backup (iOS Settings › Accounts and Settings › Backup). Each account on this browser has its own relay
// stores; one is active at a time, and switching reloads into the other. Accounts sign with an extension or a bunker:
// the web app never holds a secret key, so there is no key import or "Reveal Key" here (the iPhone has both).
import { useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { loadAccounts, rememberAccount } from "../session.js"
import { switchAccount, removeAccount } from "../signer/accounts.js"
import { exportNotes, importNotes } from "../net/backup.js"
import { pool } from "../net/pool.js"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { SignInOptions, accountName, methodLabel } from "./SignInScreen.jsx"
import "../styles/accounts.css"

export function AccountsScreen({ ctx }) {
  const [accounts, setAccounts] = useState(loadAccounts)
  const [open, setOpen] = useState("") // the account whose actions are showing
  const [adding, setAdding] = useState(false)
  const [note, setNote] = useState("")
  const active = ctx.session.pubkey

  // Adding doesn't switch (as on the iPhone): the new account is remembered, and its sign-in signer is closed.
  const added = async ({ signer, session }) => {
    signer?.close?.()
    rememberAccount(session)
    setAccounts(loadAccounts())
    setAdding(false)
    setNote(session.pubkey === active ? "That's the account you're using; its sign-in is updated." : "Account added. Switch to it any time.")
  }

  return (
    <main class="screen accounts">
      <header class="screen-head"><h2>Accounts</h2></header>
      <div class="section-label">On this browser</div>
      {accounts.map(a => (
        <AccountRow key={a.pubkey} account={a} active={a.pubkey === active} open={open === a.pubkey} ctx={ctx}
          onToggle={() => setOpen(open === a.pubkey ? "" : a.pubkey)}
          onRemoved={msg => { setAccounts(loadAccounts()); setOpen(""); setNote(msg) }} />
      ))}
      {note && <p class="status-line">{note}</p>}
      {adding
        ? <section class="card add-account">
            <h3>Add an account</h3>
            <p class="muted small">Sign in with the account's own extension or bunker. Your current account stays signed in.</p>
            <SignInOptions onSignedIn={added} />
            <button onClick={() => setAdding(false)}>Cancel</button>
          </section>
        : <button class="add-account-button" onClick={() => { setAdding(true); setNote("") }}>Add account</button>}
      <BackupCard ctx={ctx} />
      <section class="card">
        <h3>Your keys</h3>
        <p class="muted small">Nostr Vault on the web never holds your secret key: your extension or bunker keeps it, and signs for you. Back up your key there. A bunker's connection to this browser is stored encrypted, and removing the account or signing out asks the bunker to drop it.</p>
      </section>
    </main>
  )
}

function AccountRow({ account, active, open, ctx, onToggle, onRemoved }) {
  const p = useProfile(account.pubkey)
  const [busy, setBusy] = useState("")
  const [confirm, setConfirm] = useState(false)
  const [err, setErr] = useState("")
  const name = accountName(account, p)
  const act = (label, fn) => async () => {
    setBusy(label); setErr("")
    try { await fn() } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const doSwitch = act("switch", () => switchAccount({ account, vault: ctx.vault, signer: ctx.signer }))
  const doRemove = act("remove", async () => {
    const { failed, revoked } = await removeAccount({ account, pool })
    const parts = [`${name} removed from this browser.`]
    if (failed.length) parts.push(`${failed.length} of its stores weren't deleted (Nostr Vault may be open in another tab); they're deleted when it signs in here again and signs out.`)
    if (revoked === false) parts.push("Its bunker didn't confirm it dropped this browser's connection: revoke it in your bunker app.")
    onRemoved(parts.join(" "))
  })

  return (
    <div class={open ? "account open" : "account"}>
      <button class="person-row account-row" aria-expanded={open} onClick={onToggle}>
        <Avatar pubkey={account.pubkey} size={40} ring={active} />
        <span class="person-names">
          <span class="author-name">{name}</span>
          <span class="person-sub">{methodLabel(account)}</span>
        </span>
        {active && <span class="you-badge">ACTIVE</span>}
      </button>
      {open && <div class="account-actions">
        <div class="mono account-npub">{npubEncode(account.pubkey)}</div>
        {active
          ? confirm
            ? <>
                <p class="muted small">Signing out deletes everything this browser keeps for {name}: its relay's notes, messages and files here, and its sign-in. Your notes on other relays and on your phone stay.</p>
                <div class="row"><button class="danger" onClick={ctx.signOut}>Sign out</button><button onClick={() => setConfirm(false)}>Cancel</button></div>
              </>
            : <button class="danger" onClick={() => setConfirm(true)}>Sign out</button>
          : confirm
            ? <>
                <p class="muted small">This removes {name} from this browser and deletes its relay's copy here{account.method === "nip46" ? ", and asks its bunker to drop this browser's connection" : ""}. Nothing on other relays changes. You'll need its signer to add it again.</p>
                <div class="row"><button class="danger" disabled={!!busy} onClick={doRemove}>{busy === "remove" ? "Removing…" : "Remove account"}</button><button disabled={!!busy} onClick={() => setConfirm(false)}>Cancel</button></div>
              </>
            : <div class="row">
                <button class="primary" disabled={!!busy} onClick={doSwitch}>{busy === "switch" ? "Switching…" : "Switch to this account"}</button>
                <button class="danger" disabled={!!busy} onClick={() => setConfirm(true)}>Remove account</button>
              </div>}
        {err && <p class="error small">{err}</p>}
      </div>}
    </div>
  )
}

const NAMES = { outbox: "your notes", private: "private notes", chat: "messages", inbox: "inbox", feed: "feed cache" }
const summary = counts => Object.entries(counts).map(([n, c]) => `${NAMES[n] ?? n} ${typeof c === "number" ? c : c.stored}`).join(", ")
const events = n => n === 1 ? "1 event" : `${n} events`

// iOS Settings › Backup › Notes: the same .zip, so each restores the other's.
function BackupCard({ ctx }) {
  const [busy, setBusy] = useState("")
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")
  const run = (label, fn) => async () => {
    setBusy(label); setErr(""); setStatus("")
    try { await fn() } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const doExport = run("export", async () => {
    const { blob, counts } = await exportNotes({ vault: ctx.vault, pubkey: ctx.session.pubkey, onProgress: n => setStatus(`Reading ${NAMES[n] ?? n}…`) })
    const url = URL.createObjectURL(blob)
    const a = Object.assign(document.createElement("a"), { href: url, download: `nostrvault-backup-${new Date().toISOString().slice(0, 10)}.zip` })
    document.body.append(a); a.click(); a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 60_000)
    setStatus(`Saved: ${summary(counts)}.`)
  })
  const doImport = e => {
    const file = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!file) return
    run("import", async () => {
      const { counts, skipped } = await importNotes({ vault: ctx.vault, pubkey: ctx.session.pubkey, bytes: new Uint8Array(await file.arrayBuffer()), onProgress: n => setStatus(`Restoring ${NAMES[n] ?? n}…`) })
      if (!Object.keys(counts).length) throw new Error("That .zip has no notes in it. Choose a Nostr Vault notes backup.")
      const refused = Object.values(counts).reduce((n, c) => n + c.refused + c.bad, 0)
      setStatus(`Restored: ${summary(counts)}.` + (refused ? ` ${events(refused)} not restored: not this account's, or damaged.` : "") + (skipped.length ? ` Skipped ${skipped.join(", ")}.` : ""))
    })()
  }
  return (
    <section class="card backup">
      <h3>Backup</h3>
      <p class="muted small">Your notes, private notes, messages and feed cache from this browser's relay, as a .zip. It's the same file the iPhone app makes in Settings › Backup, so either one restores the other. Photos and videos aren't in it.</p>
      <div class="row">
        <button disabled={!!busy} onClick={doExport}>{busy === "export" ? "Exporting…" : "Export notes"}</button>
        <label class={busy ? "button disabled" : "button"}>
          {busy === "import" ? "Restoring…" : "Import notes"}
          <input type="file" accept=".zip,application/zip" disabled={!!busy} onChange={doImport} hidden />
        </label>
      </div>
      {status && <p class="muted small">{status}</p>}
      {err && <p class="error small">{err}</p>}
    </section>
  )
}
