// Send, as on the iPhone (WalletLightningTab+Send, +LNURL): one box for an invoice, a lightning address or an LNURL.
// THIS SPENDS MONEY. The amount is shown before anything happens, and a second "Pay" in a confirm step is the only
// thing that pays; a timeout clears the box, since paying again could pay twice.
import { useEffect, useState } from "preact/hooks"
import { WalletTimeout } from "../net/wallet.js"
import { checkAmount, invoiceAmount, parsePayTarget, payBolt11, payLnurl, resolvePayTarget } from "../net/wallet-send.js"

const IRREVERSIBLE = "Lightning payments cannot be reversed."

export function WalletSend({ wallet, resolve = resolvePayTarget, payInvoiceText = payBolt11, payAddress = payLnurl }) {
  const [text, setText] = useState("")
  const [pay, setPay] = useState(null) // the resolved LNURL pay request
  const [looking, setLooking] = useState(false)
  const [lookErr, setLookErr] = useState("")
  const [sats, setSats] = useState("")
  const [comment, setComment] = useState("")
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [done, setDone] = useState("")
  const target = parsePayTarget(text)
  const lnurlKey = target && target.kind !== "invoice" ? JSON.stringify(target) : ""

  // Look an address or LNURL up once typing stops (resolveLNURLIfNeeded: 400 ms).
  useEffect(() => {
    setPay(null); setLookErr(""); setComment(""); setConfirming(false)
    if (!lnurlKey) { setLooking(false); return }
    setLooking(true)
    let live = true
    const t = setTimeout(async () => {
      try {
        const p = await resolve(JSON.parse(lnurlKey))
        if (!live) return
        setPay(p)
        const fixed = checkAmount(p, 1)
        setSats(fixed.minSats === fixed.maxSats ? String(fixed.minSats) : "")
      } catch (e) {
        if (!live) return
        const tg = JSON.parse(lnurlKey)
        setLookErr(tg.kind === "address" ? `Couldn't find the lightning address ${tg.address}. Check the spelling. (${e?.message ?? e})` : `Couldn't open this: ${e?.message ?? e}`)
      } finally { if (live) setLooking(false) }
    }, 400)
    return () => { live = false; clearTimeout(t) }
  }, [lnurlKey])

  const n = Math.floor(Number(sats))
  const check = pay ? checkAmount(pay, n) : null
  const amount = target?.kind === "invoice" ? invoiceAmount(target.invoice) : null
  const stakes = target?.kind === "invoice"
    ? amount.sats != null ? `This sends ${amount.sats.toLocaleString()} sats from your wallet. ${IRREVERSIBLE}`
      : amount.unspecified ? `This invoice names no amount, so your wallet decides what to send, and it may refuse it. ${IRREVERSIBLE}`
      : `Nostr Vault can't read this invoice, so it can't tell you what it will cost. Your wallet will pay whatever it says. ${IRREVERSIBLE}`
    : check?.ok ? `This sends ${n.toLocaleString()} sats to ${target.address ?? pay.host}. ${IRREVERSIBLE}` : ""

  const send = async () => {
    setConfirming(false); setBusy(true); setErr(""); setDone("")
    try {
      if (target.kind === "invoice") await payInvoiceText(wallet.conn, target.invoice)
      else await payAddress(wallet.conn, pay, { sats: n, comment })
      setDone(target.kind === "invoice" && amount.sats == null ? "Payment sent." : `Sent ${(amount?.sats ?? n).toLocaleString()} sats.`)
      setText(""); setSats("") // the balance and History reload themselves (wallet.js onPaid)
    } catch (e) {
      // No answer is not a failure: the wallet may still pay. Clear the box so Pay isn't one click from paying twice.
      if (e instanceof WalletTimeout) { setErr("Your wallet didn't confirm in time. The payment may still go through, so check History before sending again."); setText("") }
      else setErr(String(e?.message ?? e))
    } finally { setBusy(false) }
  }
  const ready = !busy && (target?.kind === "invoice" || check?.ok)

  return (
    <section class="card wallet-card">
      <h3>Send</h3>
      <textarea class="wallet-uri" rows={2} autocomplete="off" autocapitalize="off" spellcheck={false} aria-label="Invoice, lightning address or LNURL"
        placeholder="Invoice, lightning address or LNURL" value={text} onInput={e => { setText(e.currentTarget.value); setDone(""); setErr(""); setConfirming(false) }} />
      {text.trim() && !target && <p class="muted small">Not something this wallet can pay. Paste a lightning invoice, a lightning address (name@domain.com) or an LNURL.</p>}
      {target?.kind === "invoice" && (amount.sats != null
        ? <p class="wallet-paying">Paying {amount.sats.toLocaleString()} sats</p>
        : <p class="muted small">{amount.unspecified ? "This invoice names no amount, and Nostr Vault can't set one. Your wallet will probably refuse it." : "Not an invoice this app can read. Check it before you pay."}</p>)}
      {looking && <p class="muted small">Looking it up…</p>}
      {lookErr && <p class="error" role="alert">{lookErr}</p>}
      {pay && <div class="wallet-lnurl">
        <p class="wallet-to"><strong>To {target?.address ?? pay.host}</strong>{pay.note && <span class="muted small">{pay.note}</span>}</p>
        {check.unpayable
          ? <p class="error">This service only takes amounts that aren't a whole number of sats, so this wallet can't pay it.</p>
          : check.minSats === check.maxSats
          ? <p class="wallet-paying">Amount: {check.minSats.toLocaleString()} sats</p>
          : <><label class="wallet-row"><span>Amount</span>
              <input class="wallet-sats" type="number" inputmode="numeric" min={check.minSats} max={check.maxSats} placeholder="sats" value={sats}
                onInput={e => { setSats(e.currentTarget.value); setConfirming(false) }} aria-label="Amount in sats" /></label>
            <p class={`small ${check.tooSmall || check.tooLarge ? "error" : "muted"}`}>
              {check.tooSmall ? `At least ${check.minSats.toLocaleString()} sats.` : check.tooLarge ? `At most ${check.maxSats.toLocaleString()} sats.` : `${check.minSats.toLocaleString()} to ${check.maxSats.toLocaleString()} sats.`}</p></>}
        {pay.commentAllowed > 0 && <label class="wallet-row"><span>Comment</span>
          <input type="text" maxLength={pay.commentAllowed} placeholder="Optional" value={comment} onInput={e => setComment(e.currentTarget.value)} /></label>}
      </div>}
      {(target?.kind === "invoice" || pay) && !confirming &&
        <button type="button" class="primary" disabled={!ready} onClick={() => setConfirming(true)}>
          {busy ? "Sending…" : target?.kind === "invoice" ? "Pay invoice" : check?.ok ? `Send ${n.toLocaleString()} sats` : "Send"}</button>}
      {confirming && <div class="wallet-confirm" role="alertdialog" aria-label="Confirm payment">
        <p>{stakes}</p>
        <div class="wallet-row"><button type="button" onClick={() => setConfirming(false)}>Cancel</button>
          <button type="button" class="primary" onClick={send}>Pay</button></div>
      </div>}
      {err && <p class="error" role="alert">{err}</p>}
      {done && <p class="wallet-sent" role="status">✓ {done}</p>}
    </section>
  )
}
