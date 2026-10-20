// The wallet's payment history, as on the iPhone (WalletLightningTab+History): newest first, Show more, a zap shown
// as who it came from or went to and what it was for. A wallet that doesn't share history says so.
import { useEffect, useState } from "preact/hooks"
import { AuthorName } from "../components/NoteCard.jsx"
import { ago } from "../components/time.js"
import { onPaid } from "../net/wallet.js"
import { HISTORY_PAGE, counterparty, isUnsupported, listTransactions, mergeTransactions } from "../net/wallet-history.js"

export function WalletHistory({ wallet, list = listTransactions }) {
  const [txs, setTxs] = useState([])
  const [busy, setBusy] = useState(false)
  const [more, setMore] = useState(false)
  const [unsupported, setUnsupported] = useState(false)
  const [err, setErr] = useState("")
  const load = async reset => {
    setBusy(true); setErr("")
    try {
      const page = await list(wallet.conn, { limit: HISTORY_PAGE, offset: reset ? 0 : txs.length })
      setTxs(reset ? page : mergeTransactions(txs, page))
      setMore(page.length >= HISTORY_PAGE)
      setUnsupported(false)
    } catch (e) {
      if (isUnsupported(e)) setUnsupported(true)
      else setErr(`Couldn't load history: ${e?.message ?? e}`)
    } finally { setBusy(false) }
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
        : <ul class="wallet-history">{txs.map(tx => <Tx key={tx.id} tx={tx} />)}</ul>}
      {more && !unsupported && <button type="button" disabled={busy} onClick={() => load(false)}>{busy ? "Loading…" : "Show more"}</button>}
    </section>
  )
}

function Tx({ tx }) {
  const incoming = tx.direction === "incoming"
  const person = counterparty(tx)
  const done = tx.state === "settled", dead = tx.state === "failed" || tx.state === "expired"
  const sub = [ago(tx.created_at), !done && tx.state, !incoming && tx.feeSats > 0 && `fee ${tx.feeSats.toLocaleString()}`].filter(Boolean).join(" · ")
  return (
    <li class="wallet-tx">
      <span class={`wallet-tx-icon${tx.zap ? " zap" : incoming ? " in" : " out"}`} aria-hidden="true">{tx.zap ? "⚡" : incoming ? "↙" : "↗"}</span>
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
