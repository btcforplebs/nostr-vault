// Block, unblock and report, from a note's ⋯ menu, a profile's ⋯ menu and Settings › Blocked. The dialogs are
// native <dialog>s (focus held inside, Escape closes). Writing the list is net/blocks.js setBlock; reporting is
// net/reports.js reportAndBlock, which blocks too, as the iPhone's Report & Block does.
import { BookmarkMenuItem } from "./BookmarkMenuItem.jsx"
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { actionContext, deleteNote, shareLink } from "../net/actions.js"
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
 * The ⋯ button and its menu. `note`: a note's menu, in the iPhone's order (FeedNoteRow+Menus): Share, Copy link,
 * Copy text, then Delete on the user's own post or Report and Block on someone else's. Without `note`, a profile's
 * (Copy npub, Nuclear unfollow, Private block, Block or Unblock, Report); nothing on the user's own profile. `className` styles the button.
 */
export function MoreMenu({ note, pubkey, className = "" }) {
  const ctx = actionContext()
  const who = note?.pubkey ?? pubkey
  const p = useProfile(who)
  const { blocked } = useBlocks(ctx ?? {})
  const [open, setOpen] = useState(false)
  const [dialog, setDialog] = useState(null) // "block" | "private-block" | "unblock" | "report" | "delete"
  const [copied, setCopied] = useState("") // which item just copied
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  const own = who === ctx?.session.pubkey
  if (!ctx || !who || (own && !note)) return null
  const isBlocked = blocked.has(who)
  const name = nameOf(p, who)
  const pick = d => () => { setOpen(false); setDialog(d) }
  const copy = (item, text) => async () => {
    await navigator.clipboard?.writeText(text)
    setCopied(item); setTimeout(() => { setCopied(""); setOpen(false) }, 900)
  }
  const text = note?.content?.trim()
  // The system share sheet where the browser has one; elsewhere Share copies the link.
  const share = note && navigator.share
    ? async () => { setOpen(false); await navigator.share({ url: shareLink(note) }).catch(() => {}) }
    : note && copy("share", note && shareLink(note))

  return (
    // Clicks stay here: the card around a note's menu opens its thread on a click.
    <span class="more-wrap" ref={ref} onClick={e => e.stopPropagation()}>
      <button type="button" class={className} aria-label="More" title="More" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d={DOTS} /></svg>
      </button>
      {open && (
        <div class="more-menu" role="menu">
          {!note && <button role="menuitem" onClick={copy("npub", npubEncode(who))}>{copied === "npub" ? "Copied" : "Copy npub"}</button>}
          {note && <button role="menuitem" onClick={share}>{copied === "share" ? "Link copied" : "Share"}</button>}
          {note && <button role="menuitem" onClick={copy("link", shareLink(note))}>{copied === "link" ? "Link copied" : "Copy link"}</button>}
          {note && text && <button role="menuitem" onClick={copy("text", text)}>{copied === "text" ? "Text copied" : "Copy text"}</button>}
          {note && <BookmarkMenuItem ctx={ctx} note={note} onDone={() => setOpen(false)} />}
          {note && <hr class="more-sep" />}
          {own && <button role="menuitem" class="danger" onClick={pick("delete")}>Delete post…</button>}
          {!own && note && <button role="menuitem" class="danger" onClick={pick("report")}>Report note…</button>}
          {/* Nuclear unfollow and Private block (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md): a profile's menu only. Nuclear
              unfollow opens the globe with your follows who follow them lit (screens/WotNuclear.jsx). */}
          {!note && !ctx.signer?.readOnly && <button role="menuitem" class="danger" onClick={() => { setOpen(false); location.hash = `#/wot/${who}/nuke` }}>Nuclear unfollow…</button>}
          {!note && !isBlocked && <button role="menuitem" class="danger" onClick={pick("private-block")}>Private block…</button>}
          {!own && (isBlocked
            ? <button role="menuitem" onClick={pick("unblock")}>Unblock {name}</button>
            : <button role="menuitem" class="danger" onClick={pick("block")}>Block {name}…</button>)}
          {!note && <button role="menuitem" class="danger" onClick={pick("report")}>Report {name}…</button>}
        </div>
      )}
      {dialog === "block" && <BlockDialog ctx={ctx} pubkey={who} name={name} onClose={() => setDialog(null)} />}
      {dialog === "private-block" && <BlockDialog ctx={ctx} pubkey={who} name={name} privateOnly onClose={() => setDialog(null)} />}
      {dialog === "unblock" && <UnblockDialog ctx={ctx} pubkey={who} name={name} onClose={() => setDialog(null)} />}
      {dialog === "report" && <ReportDialog ctx={ctx} note={note} pubkey={who} name={name} onClose={() => setDialog(null)} />}
      {dialog === "delete" && <DeleteDialog ctx={ctx} note={note} onClose={() => setDialog(null)} />}
    </span>
  )
}

/** A modal <dialog>, open while mounted. Closing it (Escape, Cancel) calls onClose. */
export function Dialog({ label, onClose, children }) {
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

/** `isPrivate` is where the private choice starts (Settings › Block Someone's "Block privately"). `privateOnly`: the
 *  ··· menu's Private block, encrypted or not at all: no box to untick, and nothing offered when the signer can't
 *  encrypt (it is never published in the clear). */
export function BlockDialog({ ctx, pubkey, name, isPrivate = false, privateOnly = false, onClose }) {
  const [priv, setPriv] = useState(isPrivate || privateOnly)
  const { busy, err, run } = useAction()
  const canPrivate = !!ctx.signer.crypto
  const go = run(async () => { await setBlock(ctx, pubkey, { block: true, isPrivate: privateOnly || priv }); onClose() })
  if (privateOnly) return (
    <Dialog label={`Privately block ${name}`} onClose={onClose}>
      <h3>Privately block {name}?</h3>
      {canPrivate ? <p class="muted">They're kept out of your web: your feeds, notifications and globe. Nobody else can see this block: it goes on the encrypted part of your list, which your phone reads too. You keep following everyone you follow.</p>
        : <p class="muted">Your signer can't encrypt, so a private block can't be made here. Use Block for a public one, or block privately from your phone.</p>}
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        {canPrivate && <button type="button" class="danger-fill" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? waiting(ctx) ?? "Blocking…" : "Block privately"}</button>}
      </div>
    </Dialog>
  )
  return (
    <Dialog label={`Block ${name}`} onClose={onClose}>
      <h3>Block {name}?</h3>
      <p class="muted">Their notes, replies and messages are hidden for you. They aren't told.</p>
      {canPrivate && (
        <label class="mod-check">
          <input type="checkbox" checked={priv} disabled={busy} onChange={e => setPriv(e.currentTarget.checked)} />
          <span>Keep this block private
            <span class="muted small">Only you can see who's on the private part of your list. It is encrypted, and your phone reads it too.</span>
          </span>
        </label>
      )}
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="button" class="danger-fill" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? waiting(ctx) ?? "Blocking…" : "Block"}</button>
      </div>
    </Dialog>
  )
}

/** The iPhone's delete alert (FeedNoteRow RowAlert.delete), word for word. */
export function DeleteDialog({ ctx, note, onClose }) {
  const { busy, err, run } = useAction()
  const go = run(async () => { await deleteNote(ctx, note); onClose() })
  return (
    <Dialog label="Delete Post" onClose={onClose}>
      <h3>Delete Post</h3>
      <p class="muted">Request deletion of this post? Not all relays honor NIP-09 deletion requests.</p>
      {err && <p class="error small" role="alert">{err}</p>}
      <div class="mod-row">
        <button type="button" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="button" class="danger-fill" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? waiting(ctx) ?? "Deleting…" : "Delete"}</button>
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
        <button type="button" class="primary" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? waiting(ctx) ?? "Unblocking…" : "Unblock"}</button>
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
        <button type="button" class="danger-fill" disabled={busy} onClick={go} aria-busy={busy || undefined}>{busy ? waiting(ctx) ?? "Reporting…" : "Report & Block"}</button>
      </div>
    </Dialog>
  )
}
