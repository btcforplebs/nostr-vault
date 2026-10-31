// Switch Account (iPhone BottomTabBar accountSwitchButton): holding the avatar opens the list of this browser's
// accounts, and picking one switches to it (signer/accounts.js switchAccount reloads into it). A tap still does what it
// did. A long press, a right-click and the context-menu key all open it. With one account there is nothing to switch
// to, so the hold does nothing, as on the iPhone.
import { useEffect, useRef, useState } from "preact/hooks"
import { loadAccounts } from "../session.js"
import { switchAccount } from "../signer/accounts.js"
import { accountName, methodLabel } from "../screens/SignInScreen.jsx"
import { Avatar } from "./Avatar.jsx"
import { useProfile } from "./useProfile.js"
import "../styles/account-switch.css"

/** The iPhone's LongPressGesture(minimumDuration: 0.4). */
export const HOLD_MS = 400
const SLOP_PX = 10

/**
 * -> { holdProps, menu }: spread holdProps on the avatar's link or button, render menu next to it. `place` is the
 * menu's class: "above" (the phone's tab bar, opening upward) or "below".
 */
/**
 * The hold gesture as props for the avatar: `onHold` after HOLD_MS of a still primary press, or at once on a right-click
 * or the context-menu key. The click that ends a hold doesn't also follow the link. `timers` is for tests.
 */
export function holdHandlers(onHold, { timers = globalThis } = {}) {
  let timer = 0, from = null, held = false
  const cancel = () => { timers.clearTimeout(timer); from = null }
  const fire = () => { held = true; globalThis.navigator?.vibrate?.(10); onHold() }
  return {
    onPointerDown: e => {
      if (e.button !== 0) return
      held = false
      from = [e.clientX, e.clientY]
      timers.clearTimeout(timer)
      timer = timers.setTimeout(fire, HOLD_MS)
    },
    onPointerMove: e => { if (from && Math.hypot(e.clientX - from[0], e.clientY - from[1]) > SLOP_PX) cancel() },
    onPointerUp: cancel, onPointerCancel: cancel, onPointerLeave: cancel,
    onContextMenu: e => { e.preventDefault(); cancel(); fire() },
    onClickCapture: e => { if (held) { e.preventDefault(); e.stopPropagation(); held = false } },
  }
}

/**
 * -> { holdProps, menu }: spread holdProps on the avatar's link or button, render menu next to it. `place` is the
 * menu's class: "above" (the phone's tab bar, opening upward) or "below".
 */
export function useAccountSwitch(ctx, { place = "above" } = {}) {
  const [open, setOpen] = useState(false)
  const handlers = useRef(null)
  handlers.current ??= holdHandlers(() => setOpen(true))
  useEffect(() => () => handlers.current.onPointerCancel(), [])
  const holdProps = loadAccounts().length > 1 ? handlers.current : {}
  const menu = open && <AccountMenu ctx={ctx} place={place} onClose={() => setOpen(false)} />
  return { holdProps, menu }
}

function AccountMenu({ ctx, place, onClose }) {
  const ref = useRef()
  const [err, setErr] = useState("")
  const [busy, setBusy] = useState("")
  const accounts = loadAccounts()
  useEffect(() => {
    ref.current?.querySelector("[role=menuitemradio]")?.focus()
    const away = e => { if (!ref.current?.contains(e.target)) onClose() }
    const key = e => {
      if (e.key === "Escape") { e.preventDefault(); onClose() }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const items = [...(ref.current?.querySelectorAll("[role=menuitemradio]") ?? [])]
        const at = items.indexOf(document.activeElement)
        items[(at + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus()
        e.preventDefault()
      }
    }
    // Next tick: the pointerdown that opened it must not close it.
    const t = setTimeout(() => addEventListener("pointerdown", away), 0)
    addEventListener("keydown", key, true)
    return () => { clearTimeout(t); removeEventListener("pointerdown", away); removeEventListener("keydown", key, true) }
  }, [])
  const pick = async account => {
    if (account.pubkey === ctx.session.pubkey) return onClose()
    setBusy(account.pubkey); setErr("")
    try { await switchAccount({ account, vault: ctx.vault, signer: ctx.signer }) }
    catch (e) { setErr(String(e?.message ?? e)); setBusy("") }
  }
  return (
    <div class={`account-switch ${place}`} role="menu" aria-label="Switch Account" ref={ref}>
      <div class="account-switch-title" aria-hidden="true">Switch Account</div>
      {accounts.map(a => <AccountItem key={a.pubkey} account={a} active={a.pubkey === ctx.session.pubkey} busy={busy === a.pubkey} disabled={!!busy} onPick={() => pick(a)} />)}
      {err && <p class="account-switch-error" role="alert">{err}</p>}
    </div>
  )
}

function AccountItem({ account, active, busy, disabled, onPick }) {
  const p = useProfile(account.pubkey)
  return (
    <button type="button" role="menuitemradio" aria-checked={active} disabled={disabled && !busy} aria-busy={busy || undefined} onClick={onPick}>
      <Avatar pubkey={account.pubkey} size={28} />
      <span class="account-switch-names">
        <span class="account-switch-name">{accountName(account, p)}</span>
        <span class="account-switch-kind">{busy ? "Switching…" : methodLabel(account)}</span>
      </span>
      {active && <svg class="account-switch-check" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>}
    </button>
  )
}
