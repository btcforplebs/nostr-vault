// The Reader napplet's Zap and ⋯ as the shell's own sheets (gap run after P8): the classic pieces, run by the shell,
// for a note whose signature the shell checked (reader-intents.js actionNote). The napplet never signs a zap request,
// a block list, a report or a deletion; the shell does, through the same code and dialogs as the classic screens.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Dialog, BlockDialog, UnblockDialog, ReportDialog, DeleteDialog } from "../components/Moderation.jsx"
import { BookmarkMenuItem } from "../components/BookmarkMenuItem.jsx"
import { AmountPicker, useWallet, zapWithFeedback } from "../components/ZapButton.jsx"
import { useProfile } from "../components/useProfile.js"
import { zapDefault } from "../net/wallet.js"
import { useBlocks } from "../components/useBlocks.js"
import { isDeleted, shareLink } from "../net/actions.js"
import { fetchProfiles, getProfile } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"

/** The author's name and lightning address: the Reader napplet fetched them for itself, so the shell may not have
 *  them yet. Fetched once (kept in memory only) if missing. */
function useAuthor(ctx, pk) {
  const p = useProfile(pk)
  useEffect(() => { if (!getProfile(pk)) fetchProfiles(ctx.vault, [pk], uniq([...(ctx.account?.relays?.read ?? []), ...PROFILE_RELAYS, ...DEFAULT_RELAYS]), { save: false }).catch(() => {}) }, [pk])
  return p
}

const nameOf = (p, pk) => p?.display_name || p?.name || npubEncode(pk).slice(0, 12) + "…"

/** Zap a note's author: the classic amount picker, or why it can't (no wallet, read-only, no lightning address).
 *  `quick`: the Reader's tap on the bolt, as the classic button's tap: the default amount goes at once (once the
 *  author's lightning address is known) and the sheet closes; only a hold opens the picker. */
export function ZapSheet({ ctx, note, onClose, quick = false }) {
  const wallet = useWallet()
  const p = useAuthor(ctx, note.pubkey)
  const name = nameOf(p, note.pubkey)
  const fired = useRef(false)
  const ready = wallet.status === "ready" && !ctx.signer?.readOnly && !!p && !!(p.lud16 || p.lud06)
  useEffect(() => {
    if (!quick || fired.current || !ready) return
    fired.current = true
    onClose()
    zapWithFeedback(ctx, { recipient: note.pubkey, note, sats: zapDefault(wallet.defaultSats), name }).catch(() => {})
  }, [quick, ready])
  const why = ctx.signer?.readOnly ? "This sign-in can't sign a zap request."
    : wallet.status !== "ready" ? "Connect a wallet in Settings › Wallet to zap."
    : p && !p.lud16 && !p.lud06 ? `${name} has no lightning address, so they can't receive zaps.` : ""
  if (why) return (
    <Dialog label={`Zap ${name}`} onClose={onClose}>
      <h3>Zap {name}</h3>
      <p class="muted">{why}</p>
      <div class="mod-row">{wallet.status !== "ready" && !ctx.signer?.readOnly && <a class="button" href="#/wallet" onClick={onClose}>Wallet</a>}<button type="button" onClick={onClose}>Close</button></div>
    </Dialog>
  )
  if (quick) return ( // the lightning address is still on its way; the zap goes once it lands
    <Dialog label={`Zap ${name}`} onClose={onClose}>
      <h3>Zap {name}</h3>
      <p class="muted">Getting {name}'s lightning address…</p>
      <div class="mod-row"><button type="button" onClick={onClose}>Close</button></div>
    </Dialog>
  )
  return (
    <Dialog label={`Zap ${name}`} onClose={onClose}>
      <h3>Zap {name}</h3>
      <AmountPicker initial={zapDefault(wallet.defaultSats)} onClose={onClose}
        onZap={(sats, comment) => { onClose(); zapWithFeedback(ctx, { recipient: note.pubkey, note, sats, name, comment }).catch(() => {}) }} />
    </Dialog>
  )
}

/** A note's ⋯: Copy link, Copy text, Bookmark, then Delete on yours or Report and Block on someone else's. `onDeleted`
 *  tells the napplet to drop the note. */
export function MenuSheet({ ctx, note, onClose, onDeleted }) {
  const p = useAuthor(ctx, note.pubkey)
  const { blocked } = useBlocks(ctx)
  const [dialog, setDialog] = useState(null)
  const [copied, setCopied] = useState("")
  // Swapping the menu for one of the classic dialogs unmounts the menu's <dialog>, whose close event would otherwise
  // take the whole sheet (the new dialog too) away.
  const switching = useRef(false)
  const pick = d => () => { switching.current = true; setDialog(d) }
  const own = note.pubkey === ctx.session.pubkey
  const name = nameOf(p, note.pubkey)
  const text = note.content?.trim()
  const copy = (item, value) => async () => { try { await navigator.clipboard?.writeText(value); setCopied(item) } catch { setCopied("") } }
  const close = () => { setDialog(null); onClose() }
  if (dialog === "block") return <BlockDialog ctx={ctx} pubkey={note.pubkey} name={name} onClose={close} />
  if (dialog === "unblock") return <UnblockDialog ctx={ctx} pubkey={note.pubkey} name={name} onClose={close} />
  if (dialog === "report") return <ReportDialog ctx={ctx} note={note} pubkey={note.pubkey} name={name} onClose={close} />
  if (dialog === "delete") return <DeleteDialog ctx={ctx} note={note} onClose={() => { if (isDeleted(note.id)) onDeleted?.(note.id); close() }} />
  return (
    <Dialog label="Note" onClose={() => { if (!switching.current) onClose() }}>
      <div class="note-menu-sheet" role="menu">
        <button type="button" role="menuitem" onClick={copy("link", shareLink(note))}>{copied === "link" ? "Link copied" : "Copy link"}</button>
        {text && <button type="button" role="menuitem" onClick={copy("text", text)}>{copied === "text" ? "Text copied" : "Copy text"}</button>}
        <BookmarkMenuItem ctx={ctx} note={note} onDone={onClose} />
        <hr class="more-sep" />
        {own && <button type="button" role="menuitem" class="danger" onClick={pick("delete")}>Delete post…</button>}
        {!own && <button type="button" role="menuitem" class="danger" onClick={pick("report")}>Report note…</button>}
        {!own && (blocked.has(note.pubkey)
          ? <button type="button" role="menuitem" onClick={pick("unblock")}>Unblock {name}</button>
          : <button type="button" role="menuitem" class="danger" onClick={pick("block")}>Block {name}…</button>)}
        <button type="button" role="menuitem" onClick={onClose}>Cancel</button>
      </div>
    </Dialog>
  )
}
