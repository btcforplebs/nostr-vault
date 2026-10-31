// The wallet, as on the iPhone (WalletSettingsView): paste a Nostr Wallet Connect link, see the balance, set the
// amount a tap on a zap button sends. The link is a key to the wallet's money: once saved it is never shown again,
// only which relay it uses and the key the wallet knows this app by (net/wallet.js says how it is kept).
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { useWallet } from "../components/ZapButton.jsx"
import { appKeyOf, connectWallet, disconnectWallet, getBalance, onPaid, setDefaultZap } from "../net/wallet.js"
import { MAX_ZAP_SATS } from "../net/zaps.js"
import { actionContext } from "../net/actions.js"
import { WalletReceive } from "./WalletReceive.jsx"
import { WalletHistory } from "./WalletHistory.jsx"
import { WalletSend } from "./WalletSend.jsx"
import { Spinner, Waiting } from "../components/Loading.jsx"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/wallet.css")

export function WalletScreen() {
  const wallet = useWallet()
  return (
    <main class="screen wallet">
      <header class="screen-head"><h2>Wallet</h2></header>
      {wallet.status === "loading" ? <Waiting>Opening your wallet…</Waiting>
        // The iPhone's order (WalletLightningTab): the balance first, then the lightning address (it heads Receive), Receive,
        // Send and History; which wallet is linked, and Disconnect, come after.
        : wallet.status === "ready" ? <><Connected wallet={wallet} /><WalletReceive wallet={wallet} pubkey={actionContext()?.session.pubkey} /><WalletSend wallet={wallet} /><WalletHistory wallet={wallet} /><Linked wallet={wallet} /></> : <Connect />}
      {wallet.status !== "loading" && <DefaultZap sats={wallet.defaultSats} />}
    </main>
  )
}

function Connect() {
  const [uri, setUri] = useState("")
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState(false)
  const save = async e => {
    e.preventDefault()
    setBusy(true); setErr("")
    try { await connectWallet(uri); setUri("") } catch (x) { setErr(String(x?.message ?? x)) } finally { setBusy(false) }
  }
  return (
    <form class="card wallet-card" onSubmit={save}>
      <h3>Wallet Connect</h3>
      <p class="muted small">Paste a nostr+walletconnect:// link from your wallet (Alby Hub, Coinos, Primal, Zeus and others make one).</p>
      {/* A password field: the link spends money, so it isn't shown on screen or kept by the browser's autofill. */}
      <input class="wallet-uri" type="password" autocomplete="off" autocapitalize="off" spellcheck={false}
        placeholder="nostr+walletconnect://…" value={uri} onInput={e => setUri(e.currentTarget.value)} aria-label="Wallet connection link" />
      {err && <p class="error" role="alert">{err}</p>}
      <button class="primary" disabled={busy || !uri.trim()} aria-busy={busy || undefined}>{busy ? "Connecting…" : "Connect wallet"}</button>
      <p class="muted small">The link stays in this browser and is deleted when you sign out. Its encryption only keeps it out of plain sight on this device: script on this page, or anyone who copies this browser's profile, can still read it. Anyone with the link can spend from the wallet, so give this app a connection with a spending limit.</p>
    </form>
  )
}

/** The balance as the hero (WalletLightningTab balanceCard): "LIGHTNING BALANCE", the sats large, a spinner while it
 *  reads and "--" when it can't. Exported for the test that it re-reads the balance after a payment (`balanceOf`: a fake
 *  there). */
export function Connected({ wallet, balanceOf = getBalance }) {
  const [balance, setBalance] = useState(null) // msat
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState(false)
  const refresh = async () => {
    setBusy(true); setErr("")
    try { setBalance(await balanceOf(wallet.conn)) } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  useEffect(() => { setBalance(null); refresh() }, [wallet.conn])
  useEffect(() => onPaid(refresh), [wallet.conn])
  return (
    <section class="card wallet-card wallet-hero" aria-label="Lightning balance">
      <div class="wallet-hero-head">
        <span class="wallet-bolt" aria-hidden="true">⚡</span><span class="wallet-hero-label">LIGHTNING BALANCE</span>
        {busy ? <Spinner label="Reading the balance" />
          : <button type="button" class="wallet-refresh" onClick={refresh} aria-label="Refresh balance" title="Refresh">↻</button>}
      </div>
      {err ? <p class="error" role="alert">{err}</p>
        : balance !== null ? <p class="wallet-balance"><span class="wallet-sats-big">{Math.floor(balance / 1000).toLocaleString()}</span> <span class="muted">sats</span></p>
        : !busy && <p class="wallet-balance"><span class="wallet-sats-big muted">--</span></p>}
    </section>
  )
}

/** Which wallet is linked (its relay and the key it knows this app by), and Disconnect. */
function Linked({ wallet }) {
  const [confirm, setConfirm] = useState(false)
  const host = (() => { try { return new URL(wallet.conn.relay).host } catch { return wallet.conn.relay } })()
  return (
    <section class="card wallet-card">
      <h3>Wallet Connect</h3>
      <div class="wallet-row"><span>Relay</span><span class="muted">{host}</span></div>
      <div class="wallet-row"><span>App key</span><span class="muted mono">{npubEncode(appKeyOf(wallet.conn)).slice(0, 20)}…</span></div>
      {confirm
        ? <div class="wallet-row"><span>Disconnect? You'll need the link again to zap.</span>
            <button type="button" class="small" onClick={() => setConfirm(false)}>Keep</button>
            <button type="button" class="small danger" onClick={() => disconnectWallet()}>Disconnect</button></div>
        : <button type="button" onClick={() => setConfirm(true)}>Disconnect wallet</button>}
    </section>
  )
}

function DefaultZap({ sats }) {
  const [value, setValue] = useState(String(sats))
  const [err, setErr] = useState("")
  useEffect(() => setValue(String(sats)), [sats])
  const save = async () => {
    setErr("")
    try { await setDefaultZap(value) } catch (e) { setErr(String(e?.message ?? e)); setValue(String(sats)) }
  }
  return (
    <section class="card wallet-card">
      <h3>Zaps</h3>
      <label class="wallet-row"><span>Default zap</span>
        <input class="wallet-sats" type="number" inputmode="numeric" min="1" max={MAX_ZAP_SATS} value={value}
          onInput={e => setValue(e.currentTarget.value)} onBlur={save} onKeyDown={e => e.key === "Enter" && e.currentTarget.blur()} />
        <span class="muted">sats</span></label>
      {err && <p class="error" role="alert">{err}</p>}
      <p class="muted small">A tap on ⚡ sends this much. Hold it to choose another amount.</p>
    </section>
  )
}
