// "Your Nostr account" on the Wallet screen: the wallet connection saved on the user's own account, NIP-44 encrypted
// to their key, so Nostr Vault on another device, or Wisp, can use it (net/nwc-backup.js). Twin of the iPhone's
// WalletSettingsView accountBackupSection and Android's wallet backup card: the same states, words and buttons.
// The saved link is never shown; the screen only says whether one is there and whether it is the wallet in use.
import { useEffect, useRef, useState } from "preact/hooks"
import { actionContext } from "../net/actions.js"
import { connectWallet, currentWalletUri, isCurrentWallet } from "../net/wallet.js"
import { BACKUP_ERRORS, clearBackup, lockAccount, offersRemove, readBackup, saveBackup } from "../net/nwc-backup.js"
import { Spinner } from "../components/Loading.jsx"

const day = at => (at ? new Date(at * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }) : "")

/** `wallet`: useWallet()'s state. `read`, `save`, `clear`: nwc-backup.js, for tests. */
export function WalletBackup({ wallet, read = readBackup, save = saveBackup, clear = clearBackup, current = actionContext }) {
  const ctx = current()
  const me = ctx?.session?.pubkey
  const [status, setStatus] = useState({ state: "unknown" })
  const [checked, setChecked] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const shownFor = useRef(null) // the account the status on screen is about
  const connected = wallet.status === "ready"
  const readOnly = !!ctx?.signer?.readOnly

  const refresh = async (askSigner = false) => {
    const c = current(), account = c?.session?.pubkey
    if (account !== shownFor.current) { setStatus({ state: "unknown" }); setChecked(false) }
    shownFor.current = account
    if (askSigner) setBusy(true)
    const next = await read(c, { askSigner, current }).catch(() => ({ state: "unknown" }))
    // A switch while it looked: that answer belongs to someone else.
    if (current()?.session?.pubkey !== account) return
    setStatus(next); setChecked(true); setBusy(false)
  }
  // Another account's errors don't carry over; "the account changed" is about the switch itself, so it stays.
  useEffect(() => { setErr(e => (e === BACKUP_ERRORS.accountChanged ? e : "")); refresh(false) }, [me])

  /** Save the wallet in use (`on`) or take the slot off, as the account the screen shows, locked to it all the way. */
  const act = async on => {
    if (busy) return
    const lock = lockAccount(current(), current)
    if (lock.pubkey !== shownFor.current) { setErr(BACKUP_ERRORS.accountChanged); refresh(false); return }
    setBusy(true); setErr("")
    let next = null
    try {
      if (on) {
        const uri = await currentWalletUri()
        if (!uri) throw new Error("No wallet is connected in this browser to save.")
        await save(lock, uri)
        next = { state: "saved", uri, savedAt: Math.floor(Date.now() / 1000) }
      } else {
        await clear(lock)
        next = { state: "empty" }
      }
    } catch (e) {
      setErr(e?.code ? e.message : on ? "Couldn't save the wallet to your account. Try again." : "Couldn't remove the wallet from your account. Try again.")
    }
    // Only the account it was done for gets the new state.
    if (next && lock.held()) setStatus(next)
    setBusy(false)
  }
  const use = async () => {
    setBusy(true); setErr("")
    try { await connectWallet(status.uri) } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  if (!checked || !me) return null
  const same = uri => isCurrentWallet(uri)
  const toggle = isOn => (
    <label class="wallet-row wallet-toggle">
      <span>Save wallet to my Nostr account</span>
      <input type="checkbox" role="switch" checked={isOn} disabled={busy || readOnly} onChange={e => act(e.currentTarget.checked)} />
    </label>
  )
  const replace = connected && !readOnly && <button type="button" disabled={busy} onClick={() => act(true)}>Save this wallet instead</button>
  const again = (label, ask) => <button type="button" class="small" disabled={busy} onClick={() => refresh(ask)}>{label}</button>
  const s = status
  return (
    <section class="card wallet-card wallet-backup" aria-label="Wallet on your Nostr account">
      <div class="wallet-hero-head"><h3>Your Nostr account</h3>{busy && <Spinner label="Working" />}</div>
      {s.state === "unknown" && <><p class="muted small">Couldn't check your Nostr account for a saved wallet.</p>{again("Check again", false)}</>}
      {s.state === "empty" && <>
        {connected ? toggle(false) : <p class="muted small">No wallet saved on your Nostr account.</p>}
        {/* One relay's answer decides "empty"; a slower one may still hold a wallet, so it can be asked again. */}
        {again("Check again", false)}
      </>}
      {s.state === "saved" && (connected ? toggle(same(s.uri)) : <button type="button" class="primary" disabled={busy} onClick={use}>Use saved wallet</button>)}
      {s.state === "needsSigner" && <>
        <p class="muted small">A wallet is saved on your Nostr account ({day(s.savedAt)}). Your signer has to open it.</p>
        {again("Load with signer", true)}{replace}
      </>}
      {s.state === "unreadable" && <>
        <p class="muted small">A wallet is saved on your Nostr account ({day(s.savedAt)}), but this browser can't read it.</p>
        {!readOnly && again("Try again", true)}{replace}
      </>}
      {/* Offered whenever a wallet may be on the account: removing needs no proof it is there. */}
      {!readOnly && offersRemove(s, { connected, same }) && <button type="button" class="danger" disabled={busy} onClick={() => act(false)}>Remove from my account</button>}
      {s.state === "saved" && connected && !same(s.uri) && <p class="muted small">Your account holds a different wallet, saved {day(s.savedAt)}. Turning this on replaces it.</p>}
      {s.state === "saved" && !connected && <p class="muted small">Saved {day(s.savedAt)}. It may have come from Nostr Vault on another device or from Wisp.</p>}
      {readOnly && <p class="muted small">{BACKUP_ERRORS.readOnly}</p>}
      <p class="muted small">Stored encrypted to your key (NIP-44) on your relays, so Nostr Vault on your other devices, or Wisp, can use it. Anyone who has your key can read it and spend from this wallet.</p>
      {err && <p class="error" role="alert">{err}</p>}
    </section>
  )
}
