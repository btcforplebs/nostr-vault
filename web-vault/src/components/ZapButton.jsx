import { useEffect, useRef, useState } from "preact/hooks"
import { actionContext, addressOf } from "../net/actions.js"
import { formatSats } from "../net/notifications.js"
import { ensureWallet, onWallet, walletState } from "../net/wallet.js"
import { MAX_ZAP_SATS, PRESET_SATS, onZapTotals, wantTotals, zap, zapTotal } from "../net/zaps.js"
import { ZappersList } from "./ZappersList.jsx"
import { useProfile } from "./useProfile.js"
import { showToast } from "./Toast.jsx"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/wallet.css")

const BOLT = "M13 2 4.5 13.5H11L10 22l8.5-11.5H12z"
const HOLD_MS = 500

/** A zap's pill (ZapNotificationBanner ZapPill): "Zapping Name" with the sats while it goes, "Zapped Name" for 3 s once
 *  paid, "Zap failed" for 5 s. `name` is the profile's name, else the first 8 of the pubkey (ZapService). */
export function zapFeedback(status, name, sats) {
  const amount = `${Number(sats).toLocaleString("en-US")} sats`
  const label = status === "sending" ? `Zapping ${name}` : status === "sent" ? `Zapped ${name}` : "Zap failed"
  return {
    message: `${label} · ${amount}`, label: `${label}, ${amount}`, icon: status === "failed" ? "warn" : "bolt",
    tone: status === "sending" ? "accent" : status === "sent" ? "success" : "error", seconds: status === "sending" ? 0 : status === "sent" ? 3 : 5,
  }
}
let zapsShown = 0

/** zap(), with its pill from "Zapping" to "Zapped" or "Zap failed". Each zap keeps its own pill, as two zaps in a row
 *  each get theirs on the iPhone. Throws what zap() threw. `pay` is for tests. */
export async function zapWithFeedback(ctx, { recipient, note, sats, name }, pay = zap) {
  const key = `zap:${++zapsShown}`, who = name || recipient.slice(0, 8)
  showToast({ key, ...zapFeedback("sending", who, sats) })
  try {
    // An article (any addressable note) is zapped by its address too, so clients counting by address see it.
    const address = note ? addressOf(note) ?? undefined : undefined
    await pay(ctx, { recipient, note, sats, ...(address ? { address } : {}) })
    showToast({ key, ...zapFeedback("sent", who, sats) })
  } catch (e) {
    showToast({ key, ...zapFeedback("failed", who, sats) })
    throw e
  }
}

/** The signed-in account's wallet, read on first use and re-rendering when it changes. */
export function useWallet() {
  const pubkey = actionContext()?.session.pubkey
  const [w, setW] = useState(walletState)
  useEffect(() => { const off = onWallet(setW); ensureWallet(pubkey); setW(walletState()); return off }, [pubkey])
  return w
}

/**
 * The zap button, as on the iPhone (FeedNoteRow+NoteBody, PersonProfileView.zapPill): a tap zaps the default
 * amount, a long press (or right-click) picks one. With no wallet a note still shows the sats others sent, and a
 * profile shows nothing. `note` zaps that note's author for it; `pubkey` alone zaps the person. `pickFirst`: a tap opens
 * the amounts with your default filled in, as the iPhone's article reader does (ArticleReaderView zapSheetContext).
 */
export function ZapButton({ note, pubkey, pickFirst = false }) {
  const ctx = actionContext()
  const wallet = useWallet()
  const id = note?.id
  const recipient = note?.pubkey ?? pubkey
  const [total, setTotal] = useState(() => id ? zapTotal(id) : null)
  const [state, setState] = useState(null) // null | "busy" | "sent" | { error }
  const [picking, setPicking] = useState(false)
  const [listing, setListing] = useState(false) // who zapped (ZappersListView)
  const hold = useRef(null), held = useRef(false)
  // No lightning address on a loaded profile: the bolt dims and a tap says why, as on the iPhone, rather than failing.
  const profile = useProfile(recipient)
  const noLightning = !!profile && !profile.lud16 && !profile.lud06

  useEffect(() => {
    if (!id) return
    setTotal(zapTotal(id))
    const off = onZapTotals(z => { if (z === id) setTotal(zapTotal(id)) })
    if (ctx) wantTotals(ctx, id)
    return off
  }, [id, !!ctx])

  if (!ctx) return null
  const sats = total?.sats ?? 0
  const trusted = pk => pk === ctx.session.pubkey || ctx.account?.follows?.includes(pk)
  const list = listing && <ZappersList noteId={id} trusted={trusted} onClose={() => setListing(false)}
    onPerson={pk => { setListing(false); location.hash = `#/profile/${pk}` }} />
  if (wallet.status !== "ready" || ctx.signer?.readOnly) { // read-only can't sign the zap request
    if (!sats) return null
    // No wallet to zap from, but the sats others sent still show, and who sent them.
    return (
      <span class="zap">
        <button type="button" class="note-action zap-total" aria-label={`${formatSats(sats)} sats zapped. Show who zapped`} aria-haspopup="dialog"
          aria-expanded={listing} onClick={e => { e.stopPropagation(); setListing(!listing) }}><Bolt filled />{formatSats(sats)}</button>
        {list}
      </span>
    )
  }

  const send = async amount => {
    setPicking(false)
    setState("busy")
    try {
      await zapWithFeedback(ctx, { recipient, note, sats: amount, name: profile?.name })
      setState("sent")
    } catch (e) {
      setState({ error: String(e?.message ?? e) })
    }
  }
  const busy = state === "busy", zapped = state === "sent" || total?.mine, error = state?.error
  const verb = note ? "Zap" : `Zap ${formatSats(wallet.defaultSats)}`
  const name = error ? `Zap didn't go through: ${error}` : busy ? "Zapping…" : zapped ? `Zapped${sats ? `, ${formatSats(sats)} sats` : ""}`
    : `${verb}${sats ? `, ${formatSats(sats)} sats zapped` : ""}${pickFirst ? ". Choose an amount" : ". Hold to choose an amount"}`

  // A hold opens the picker; the click that ends the hold must not also zap.
  const down = () => { held.current = false; hold.current = setTimeout(() => { held.current = true; setPicking(true) }, HOLD_MS) }
  const up = () => clearTimeout(hold.current)
  const click = () => {
    if (held.current) { held.current = false; return }
    if (noLightning) return setState({ error: "This profile has no lightning address, so it can't receive zaps" })
    if (!busy) pickFirst ? setPicking(true) : send(wallet.defaultSats)
  }

  return (
    <span class="zap">
      <button type="button" class={`note-action zap-button${zapped ? " sent" : ""}${error ? " failed" : ""}${!note ? " wide" : ""}${noLightning && !zapped ? " no-lightning" : ""}`}
        aria-label={name} title={name} aria-busy={busy || undefined} aria-haspopup="dialog" aria-expanded={picking}
        onPointerDown={noLightning ? undefined : down} onPointerUp={up} onPointerLeave={up} onClick={click}
        onContextMenu={e => { e.preventDefault(); up(); if (!busy) setPicking(true) }}>
        <Bolt filled={zapped} />
        {!note && verb}
      </button>
      {note && sats > 0 && <button type="button" class="note-action zap-count" aria-label={`${formatSats(sats)} sats zapped. Show who zapped`}
        aria-haspopup="dialog" aria-expanded={listing} onClick={e => { e.stopPropagation(); setPicking(false); setListing(!listing) }}>{formatSats(sats)}</button>}
      {error && <span class="zap-error" role="alert">{error}</span>}
      {picking && <AmountPicker initial={wallet.defaultSats} onZap={send} onClose={() => setPicking(false)} />}
      {list}
    </span>
  )
}

/** The iPhone's custom zap amounts (CustomZapSheet): the presets, or any amount typed in. */
function AmountPicker({ initial, onZap, onClose }) {
  const [amount, setAmount] = useState(String(initial))
  const n = Math.floor(Number(amount))
  const ok = Number.isFinite(n) && n >= 1 && n <= MAX_ZAP_SATS
  const box = useRef(null)
  useEffect(() => { box.current?.querySelector("input")?.focus() }, [])
  // Clicks inside stay here: the card under it opens its thread on a click.
  return (
    <div class="zap-picker" role="dialog" aria-label="Zap amount" ref={box} onClick={e => e.stopPropagation()}
      onKeyDown={e => { if (e.key === "Escape") onClose() }}>
      <div class="zap-presets">
        {PRESET_SATS.map(p => <button type="button" class={n === p ? "on" : ""} onClick={() => setAmount(String(p))}>{formatSats(p)}</button>)}
      </div>
      <label class="zap-custom"><span>Sats</span>
        <input type="number" inputmode="numeric" min="1" max={MAX_ZAP_SATS} value={amount} onInput={e => setAmount(e.currentTarget.value)}
          onKeyDown={e => { if (e.key === "Enter" && ok) onZap(n) }} /></label>
      <div class="zap-picker-row">
        <button type="button" onClick={onClose}>Cancel</button>
        <button type="button" class="primary" disabled={!ok} onClick={() => onZap(n)}>{ok ? `Zap ${n.toLocaleString()} sats` : "Zap"}</button>
      </div>
    </div>
  )
}

const Bolt = ({ filled }) => (
  <svg viewBox="0 0 24 24" width="16" height="16" fill={filled ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true">
    <path d={BOLT} />
  </svg>
)
