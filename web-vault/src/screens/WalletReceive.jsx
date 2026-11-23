// Receive, as on the iPhone (WalletLightningTab receiveCard, lightningAddressCard): your lightning address to copy,
// and an invoice from the connected wallet for an amount, shown as a QR code with Copy. Receiving spends nothing.
import { useState } from "preact/hooks"
import { QrCode } from "../components/QrCode.jsx"
import { makeInvoice } from "../net/wallet.js"
import { invoiceMsat } from "../net/zaps.js"
import { useProfile } from "../components/useProfile.js"

export function WalletReceive({ wallet, pubkey, make = makeInvoice }) {
  const [sats, setSats] = useState("")
  const [description, setDescription] = useState("")
  const [invoice, setInvoice] = useState(null)
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState(false)
  // Live, so the address shows once the profile arrives, not only when it was already cached.
  const address = (useProfile(pubkey)?.lud16 ?? "").trim()
  const create = async e => {
    e.preventDefault()
    setBusy(true); setErr(""); setInvoice(null)
    try { setInvoice(await make(wallet.conn, { sats: Math.floor(Number(sats)), description }, { amountOf: invoiceMsat })) }
    catch (x) { setErr(String(x?.message ?? x)) } finally { setBusy(false) }
  }
  return (
    <section class="card wallet-card">
      <h3>Receive</h3>
      {address && <div class="wallet-row"><span>Lightning address</span><span class="muted mono">{address}</span><CopyButton text={address} label="Copy lightning address" /></div>}
      <form onSubmit={create}>
        <label class="wallet-row"><span>Amount</span>
          <input class="wallet-sats" type="number" inputmode="numeric" min="1" max="10000000" placeholder="sats" value={sats}
            onInput={e => setSats(e.currentTarget.value)} aria-label="Amount in sats" /></label>
        <label class="wallet-row"><span>Description</span>
          <input type="text" maxLength={200} placeholder="Optional" value={description} onInput={e => setDescription(e.currentTarget.value)} /></label>
        {err && <p class="error" role="alert">{err}</p>}
        <button class="primary" disabled={busy || !(Number(sats) >= 1)} aria-busy={busy || undefined}>{busy ? "Creating…" : "Create invoice"}</button>
      </form>
      {invoice && <Invoice invoice={invoice} />}
    </section>
  )
}

/** The invoice as a QR code (upper case, as the iPhone encodes it: a smaller code for the same invoice), its text and Copy. */
function Invoice({ invoice }) {
  return (
    <div class="wallet-invoice">
      <QrCode text={invoice.toUpperCase()} label={`QR code for an invoice of ${(invoiceMsat(invoice) / 1000).toLocaleString()} sats`} />
      <p class="muted mono small wallet-invoice-text">{invoice}</p>
      <CopyButton text={invoice} label="Copy invoice" wide />
    </div>
  )
}

export { QrCode } // components/QrCode.jsx; still exported here for the screens that import it from this file

function CopyButton({ text, label, wide }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try { await navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 2000) } catch {}
  }
  return <button type="button" class={wide ? "" : "small"} aria-label={label} onClick={copy}>{copied ? "Copied!" : wide ? label : "Copy"}</button>
}
