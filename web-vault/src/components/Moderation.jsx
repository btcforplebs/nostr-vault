// Block, unblock and report, from a note's ⋯ menu, a profile's ⋯ menu and Settings › Blocked. The dialogs are
// native <dialog>s (focus held inside, Escape closes). Writing the list is net/blocks.js setBlock; reporting is
// net/reports.js reportAndBlock, which blocks too, as the iPhone's Report & Block does.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { actionContext } from "../net/actions.js"
import { setBlock } from "../net/blocks.js"
import { REASONS, reportAndBlock } from "../net/reports.js"
import { useProfile } from "./useProfile.js"
import { useBlocks } from "./useBlocks.js"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/moderation.css")

const DOTS = "M5 12h.01M12 12h.01M19 12h.01"
const nameOf = (p, pubkey) => p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"
const waiting = ctx => (ctx.signer.method === "nip46" ? "Waiting for your signer…" : null)

/**
 * The ⋯ button and its menu. `note`: a note's menu (Report note, Block). Without it, a profile's (Copy npub, Block or
 * Unblock, Report). Nothing for the user's own notes or profile. `className` styles the button for where it sits.
 */
export function MoreMenu({ note, pubkey, className = "" }) {
  const ctx = actionContext()
  const who = note?.pubkey ?? pubkey
  const p = useProfile(who)
  const { blocked } = useBlocks(ctx ?? {})
  const [open, setOpen] = useState(false)
  const [dialog, setDialog] = useState(null) // "block" | "unblock" | "report"
  const [copied, setCopied] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  if (!ctx || !who || who === ctx.session.pubkey) return null
  const isBlocked = blocked.has(who)
  const name = nameOf(p, who)
  const pick = d => () => { setOpen(false); setDialog(d) }
  const copy = async () => { await navigator.clipboard?.writeText(npubEncode(who)); setCopied(true); setTimeout(() => { setCopied(false); setOpen(false) }, 900) }

  return (
    // Clicks stay here: the card around a note's menu opens its thread on a click.
    <span class="more-wrap" ref={ref} onClick={e => e.stopPropagation()}>
      <button type="button" class={className} aria-label="More" title="More" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d={DOTS} /></svg>
      </button>
      {open && (
        <div class="more-menu" role="menu">
          {!note && <button role="menuitem" onClick={copy}>{copied ? "Copied" : "Copy npub"}</button>}
          {note && <button role="menuitem" class="danger" onClick={pick("report")}>Report note…</button>}
          {isBlocked
            ? <button role="menuitem" onClick={pick("unblock")}>Unblock {name}</button>
            : <button role="menuitem" class="danger" onClick={pick("block")}>Block {name}…</button>}
          {!note && <button role="menuitem" class="danger" onClick={pick("report")}>Report {name}…</button>}
        </div>
      )}
      {dialog === "block" && <BlockDialog ctx={ctx} pubkey={who} name={name} onClose={() => setDialog(null)} />}
      {dialog === "unblock" && <UnblockDialog ctx={ctx} pubkey={who} name={name} onClose={() => setDialog(null)} />}
      {dialog === "report" && <ReportDialog ctx={ctx} note={note} pubkey={who} name={name} onClose={() => setDialog(null)} />}
    </span>
  )
}

/** A modal <dialog>, open while mounted. Closing it (Escape, Cancel) calls onClose. */
function Dialog({ label, onClose, children }) {
  const ref = useRef(null)
  useEffect(() => {
    const d = ref.current
    d?.showModal?.()
    return () => d?.open && d.close()
  }, [])
  return (
    <dialog ref={ref} class="mod-dialog" aria-label={label} onClose={onClose} onCancel={e => { e.preventDefault(); onClose() }}
      onClick={e => { e.stopPropagation(); if (e.target === ref.current) onClose() }}>
      <div class="mod-body">{children}</div>
    </dialog>
  )
}

/** Runs `fn` once, with the busy and error state a dialog shows. */
function useAction() {
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const run = fn => async () => {
    setBusy(true); setErr("")
    try { await fn() } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  return { busy, err, run }
}

export function BlockDialog({ ctx, pubkey, name, onClose }) {
  const [priv, setPriv] = useState(false)
  const { busy, err, run } = useAction()
  const canPrivate = !!ctx.signer.crypto
  const go = run(async () => { await setBlock(ctx, pubkey, { block: true, isPrivate: priv }); onClose() })
  return (
    <Dialog label={`Block ${name}`} onClose={onClose}>
      <h3>Block {name}?</h3>
      <p class="muted">Their notes, replies and messages are hidden for you. They aren't told.</p>
      {canPrivate && (
        <label class="mod-check">
          <input type="checkbox" checked={priv} disabled={busy} onChange={e => setPriv(e.currentTarget.checked)} />
          <span>Keep this block private
            <span class="muted small">Only you can see who's on the private part of your list. Your phone doesn't read private blocks yet, and blocking or unblocking someone there drops them.</span>
          </span>
        </label>
      )}
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="button" class="danger-fill" disabled={busy} onClick={go}>{busy ? waiting(ctx) ?? "Blocking…" : "Block"}</button>
      </div>
    </Dialog>
  )
}

export function UnblockDialog({ ctx, pubkey, name, onClose }) {
  const { busy, err, run } = useAction()
  const go = run(async () => { await setBlock(ctx, pubkey, { block: false }); onClose() })
  return (
    <Dialog label={`Unblock ${name}`} onClose={onClose}>
      <h3>Unblock {name}?</h3>
      <p class="muted">Their notes, replies and messages show again, here and on your phone.</p>
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="button" class="primary" disabled={busy} onClick={go}>{busy ? waiting(ctx) ?? "Unblocking…" : "Unblock"}</button>
      </div>
    </Dialog>
  )
}

export function ReportDialog({ ctx, note, pubkey, name, onClose }) {
  const [reason, setReason] = useState("spam")
  const [details, setDetails] = useState("")
  const [done, setDone] = useState(null)
  const { busy, err, run } = useAction()
  const go = run(async () => setDone(await reportAndBlock(ctx, { note, pubkey, reason, details })))
  if (done) {
    return (
      <Dialog label="Reported" onClose={onClose}>
        <h3>Reported</h3>
        <p class="muted">{done.alreadyBlocked ? `Thanks. You'd already blocked ${name}.` : done.blocked ? `Thanks. ${name} is blocked, so you won't see them any more.` : `The report went out, but blocking ${name} didn't: ${done.blockError}`}</p>
        <div class="mod-row"><button type="button" class="primary" onClick={onClose}>Done</button></div>
      </Dialog>
    )
  }
  return (
    <Dialog label={note ? "Report note" : `Report ${name}`} onClose={onClose}>
      <h3>{note ? "Report note" : `Report ${name}`}</h3>
      <fieldset class="mod-reasons" disabled={busy}>
        <legend>Why are you reporting this?</legend>
        {REASONS.map(r => (
          <label key={r.id} class={reason === r.id ? "mod-reason on" : "mod-reason"}>
            <input type="radio" name="report-reason" value={r.id} checked={reason === r.id} onChange={() => setReason(r.id)} />
            {r.label}
          </label>
        ))}
      </fieldset>
      <label class="mod-details">
        <span class="muted small">Additional details (optional)</span>
        <textarea rows={3} value={details} disabled={busy} onInput={e => setDetails(e.currentTarget.value)} />
      </label>
      <p class="muted small">Reporting also blocks {name} for you.</p>
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="button" class="danger-fill" disabled={busy} onClick={go}>{busy ? waiting(ctx) ?? "Reporting…" : "Report & Block"}</button>
      </div>
    </Dialog>
  )
}
