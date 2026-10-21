// The wallet's payment history, as on the iPhone (WalletLightningTab+History): newest first, Show more, a zap shown
// as who it came from or went to (their picture with a ⚡) and what it was for, dated "2 hours ago". A zap only counts
// when it involves you (ZapHistoryService.fits). A wallet that doesn't share history says so.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { actionContext } from "../net/actions.js"
import { onPaid } from "../net/wallet.js"
import { HISTORY_PAGE, counterparty, isUnsupported, listTransactions, mergeTransactions } from "../net/wallet-history.js"

/** A zap you received was made out to you; one you sent was made by you, or anonymously from a throwaway key. Any
 *  other zap request riding on your payment is somebody else's story, and the row shows as a plain payment. */
export function fits(zap, direction, me) {
  if (!zap || !me) return false
  return direction === "incoming" ? zap.recipient === me : zap.anonymous || zap.sender === me
}
export const ownZaps = (txs, me) => txs.map(tx => (tx.zap && !fits(tx.zap, tx.direction, me) ? { ...tx, zap: null, description: null } : tx))

/** "2 hours ago", "yesterday", "3 weeks ago" (the iPhone's relative date). */
export function whenText(ts, now = Date.now() / 1000, locale) {
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" })
  const d = ts - now, a = Math.abs(d)
  for (const [unit, sec] of [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]])
    if (a >= sec) return rtf.format(Math.round(d / sec), unit)
  return rtf.format(Math.round(d), "second")
}

export function WalletHistory({ wallet, list = listTransactions, me = actionContext()?.session?.pubkey }) {
  const [txs, setTxs] = useState([])
  const [busy, setBusy] = useState(false)
  const [more, setMore] = useState(false)
  const [unsupported, setUnsupported] = useState(false)
  const [err, setErr] = useState("")
  const running = useRef(false), pending = useRef(false)
  // One load at a time: a reload asked for mid-load runs after it (iPhone historyRefreshPending), so a slower,
  // older answer can't land over a newer one.
  const load = async reset => {
    if (running.current) { if (reset) pending.current = true; return }
    running.current = true
    setBusy(true); setErr("")
    try {
      const page = await list(wallet.conn, { limit: HISTORY_PAGE, offset: reset ? 0 : txs.length })
      setTxs(reset ? page : mergeTransactions(txs, page))
      setMore(page.length >= HISTORY_PAGE)
      setUnsupported(false)
    } catch (e) {
      if (isUnsupported(e)) setUnsupported(true)
      else setErr(`Couldn't load history: ${e?.message ?? e}`)
    } finally {
      running.current = false; setBusy(false)
      if (pending.current) { pending.current = false; load(true) }
    }
  }
  useEffect(() => { setTxs([]); load(true) }, [wallet.conn])
  // A payment from Send or a zap: reload from the top, so "check History" shows it.
  useEffect(() => onPaid(() => load(true)), [wallet.conn])

  return (
    <section class="card wallet-card">
      <div class="wallet-row"><h3 style="margin: 0; flex: 1">History</h3>
        {!unsupported && <button type="button" class="small" disabled={busy} onClick={() => load(true)} aria-label="Refresh history">↻</button>}</div>
      {unsupported
        ? <p class="muted small">Your wallet doesn't share its payment history with apps. If it supports it, reconnect the wallet with "transaction history" (list transactions) allowed.</p>
        : err && !txs.length ? <p class="error" role="alert">{err}</p>
        : !txs.length ? <p class="muted small">{busy ? "Loading…" : "No payments yet."}</p>
        : <ul class="wallet-history">{ownZaps(txs, me).map(tx => <Tx key={tx.id} tx={tx} />)}</ul>}
      {more && !unsupported && <button type="button" disabled={busy} onClick={() => load(false)}>{busy ? "Loading…" : "Show more"}</button>}
    </section>
  )
}

export function Tx({ tx, now }) {
  const incoming = tx.direction === "incoming"
  const person = counterparty(tx)
  const done = tx.state === "settled", dead = tx.state === "failed" || tx.state === "expired"
  const sub = [whenText(tx.created_at, now), !done && tx.state, !incoming && tx.feeSats > 0 && `fee ${tx.feeSats.toLocaleString()}`].filter(Boolean).join(" · ")
  return (
    <li class="wallet-tx">
      {person
        ? <span class="wallet-tx-icon zap" aria-hidden="true" style="position: relative; background: none">
            <Avatar pubkey={person} size={28} />
            <span style="position: absolute; right: -3px; bottom: -3px; font-size: 10px; line-height: 1; padding: 2px; border-radius: 50%; background: #ff9f0a; color: #000">⚡</span>
          </span>
        : <span class={`wallet-tx-icon${tx.zap ? " zap" : incoming ? " in" : " out"}`} aria-hidden="true">{tx.zap ? "⚡" : incoming ? "↙" : "↗"}</span>}
      <span class="wallet-tx-main">
        <span class="wallet-tx-title">{title(tx, person)}</span>
        {tx.zap && <span class="muted small wallet-tx-line">{context(tx.zap, incoming)}</span>}
        <span class={`small wallet-tx-line ${dead ? "error" : "muted"}`}>{sub}</span>
      </span>
      <span class={`wallet-tx-amount${done && incoming ? " in" : ""}${!done ? " muted" : ""}`} style={dead ? "text-decoration: line-through" : ""}>
        {incoming ? "+" : "−"}{tx.sats.toLocaleString()}
      </span>
    </li>
  )
}

function title(tx, person) {
  const incoming = tx.direction === "incoming"
  if (!tx.zap) return tx.description ?? (incoming ? "Received" : "Sent")
  if (incoming && tx.zap.anonymous) return "Anonymous zap"
  if (!person) return incoming ? "Zap received" : "Zap sent"
  return <>{incoming ? "Zap from " : "Zap to "}<AuthorName pubkey={person} /></>
}

/** What the zap was for: the sender's comment, else a post or a profile. */
const context = (zap, incoming) =>
  zap.comment ? `“${zap.comment}”` : zap.noteId ? "on a post" : incoming ? "on your profile" : "on their profile"
