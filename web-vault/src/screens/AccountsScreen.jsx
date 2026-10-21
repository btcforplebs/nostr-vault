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

// "Tap" on a touch screen (as on the iPhone), "Click" with a mouse or trackpad.
const coarse = () => globalThis.matchMedia?.("(pointer: coarse)").matches ?? false

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
      <header class="screen-head"><a class="button small" href="#/settings">‹ Settings</a><h2>Accounts &amp; Keys</h2><span style="width: 92px" /></header>
      <div class="section-label">Accounts</div>
      {accounts.map(a => (
        <AccountRow key={a.pubkey} account={a} active={a.pubkey === active} open={open === a.pubkey} ctx={ctx} others={accounts.length > 1}
          onToggle={() => setOpen(open === a.pubkey ? "" : a.pubkey)}
          onRemoved={msg => { setAccounts(loadAccounts()); setOpen(""); setNote(msg) }} />
      ))}
      <p class="settings-note muted small">{coarse() ? "Tap" : "Click"} an account to manage it.</p>
      {note && <p class="status-line">{note}</p>}
      {adding
        ? <section class="card add-account">
            <h3>Add Account</h3>
            <p class="muted small">Sign in with the account's own extension or bunker. Your current account stays signed in.</p>
            <SignInOptions onSignedIn={added} />
            <button onClick={() => setAdding(false)}>Cancel</button>
          </section>
        : <button class="add-account-button" onClick={() => { setAdding(true); setNote("") }}>+ Add Account</button>}
      <BackupCard ctx={ctx} />
      <section class="card">
        <h3>Paired vaults</h3>
        <p class="muted small">Vaults you pair on the Relay screen are paired with this browser, not with one account. A paired vault can reach whichever account is active here, and signing out of any account un-pairs them all.</p>
      </section>
      <section class="card">
        <h3>Your keys</h3>
        <p class="muted small">Nostr Vault on the web never holds your secret key: your extension or bunker keeps it, and signs for you. Back up your key there. A bunker's connection to this browser is stored encrypted, and removing the account or signing out asks the bunker to drop it.</p>
      </section>
    </main>
  )
}

function AccountRow({ account, active, open, ctx, others, onToggle, onRemoved }) {
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
        {active && <span class="you-badge">Active</span>}
      </button>
      {open && <div class="account-actions">
        <NpubLine pubkey={account.pubkey} />
        {active
          ? confirm
            ? <>
                <p class="muted small">Signing out deletes everything this browser keeps for {name}: its relay's notes, messages and files here, and its sign-in.{others ? " It also un-pairs this browser's paired vaults, for your other accounts too." : ""} Your notes on other relays and on your phone stay.</p>
                <div class="row"><button class="danger" onClick={ctx.signOut}>Sign out</button><button onClick={() => setConfirm(false)}>Cancel</button></div>
              </>
            : <button class="danger" onClick={() => setConfirm(true)}>Sign out</button>
          : confirm
            ? <>
                <p class="muted small">This removes {name} from Nostr Vault in this browser, along with its relay's copy here{account.method === "nip46" ? " and its bunker connection" : ""}. Nothing on the relays changes, but you will need its signer again to sign back in.</p>
                <div class="row"><button class="danger" disabled={!!busy} onClick={doRemove}>{busy === "remove" ? "Removing…" : "Remove Account"}</button><button disabled={!!busy} onClick={() => setConfirm(false)}>Cancel</button></div>
              </>
            : <div class="row">
                <button class="primary" disabled={!!busy} onClick={doSwitch}>{busy === "switch" ? "Switching…" : "Switch to This Account"}</button>
                <button class="danger" disabled={!!busy} onClick={() => setConfirm(true)}>Remove Account</button>
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
      const { counts, skipped, failed } = await importNotes({ vault: ctx.vault, pubkey: ctx.session.pubkey, bytes: new Uint8Array(await file.arrayBuffer()), onProgress: n => setStatus(`Restoring ${NAMES[n] ?? n}…`) })
      if (!Object.keys(counts).length) throw new Error(failed.length ? failed.join(" ") : "That .zip has no notes in it. Choose a Nostr Vault notes backup.")
      const refused = Object.values(counts).reduce((n, c) => n + c.refused + c.bad, 0)
      setStatus(`Restored: ${summary(counts)}.` + (refused ? ` ${events(refused)} not restored: not this account's, or damaged.` : "") + (skipped.length ? ` Skipped ${skipped.join(", ")}.` : "") + (failed.length ? ` ${failed.join(" ")}` : ""))
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

/** The account's full npub with Copy, as the iPhone's AccountDetailView header shows it. */
function NpubLine({ pubkey }) {
  const [copied, setCopied] = useState(false)
  const npub = npubEncode(pubkey)
  const copy = () => navigator.clipboard.writeText(npub).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500) }).catch(() => {}) // refused: the npub is still selectable
  return (
    <div class="account-npub-line">
      <div class="mono account-npub">{npub}</div>
      <button class="small" onClick={copy} aria-label="Copy npub">{copied ? "Copied" : "Copy"}</button>
    </div>
  )
}
