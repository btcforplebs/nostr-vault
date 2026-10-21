// The menu a click on a post's profile picture opens, as on the iPhone (AuthorQuickMenu): Follow or Unfollow, Web of
// Trust, then Block set apart. Full cards and compact and threaded lines all use it, so the picture means the same
// thing everywhere; the name still opens the profile. Your own picture opens your profile. Follow goes through
// net/follows.js setFollow (its wipe guards included) and Block through net/blocks.js setBlock, signed by your signer.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "./Avatar.jsx"
import { useProfile } from "./useProfile.js"
import { actionContext } from "../net/actions.js"
import { setFollow } from "../net/follows.js"
import { setBlock } from "../net/blocks.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"

const nameOf = (p, pk) => p?.display_name || p?.name || pk.slice(0, 8)

/** Follow or unfollow `pk` for the signed-in account, then re-read it so every Follow button agrees. */
export async function toggleFollow(ctx, pk, follow) {
  const { vault, signer, session, account } = ctx
  await setFollow({ vault, signer, pubkey: session.pubkey, target: pk, follow,
    readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
  await ctx.reloadAccount?.()
}

export function AvatarMenu({ pubkey, size = 40 }) {
  const ctx = actionContext()
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const esc = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [open])
  const own = !ctx || pubkey === ctx.session?.pubkey
  const click = e => {
    e.preventDefault(); e.stopPropagation()
    if (own) location.hash = `#/profile/${pubkey}`
    else setOpen(!open)
  }
  return (
    <span class="avatar-menu" ref={ref} onClick={e => e.stopPropagation()}>
      <a href={`#/profile/${pubkey}`} class="avatar-menu-photo" onClick={click} aria-haspopup={own ? undefined : "menu"} aria-expanded={own ? undefined : open}
        aria-label={own ? "Your profile" : "Profile picture: Follow, Web of Trust, Block"}>
        <Avatar pubkey={pubkey} size={size} />
      </a>
      {open && <QuickMenu ctx={ctx} pubkey={pubkey} onClose={() => setOpen(false)} />}
    </span>
  )
}

function QuickMenu({ ctx, pubkey, onClose }) {
  const p = useProfile(pubkey)
  const name = nameOf(p, pubkey)
  const [busy, setBusy] = useState("")
  const [note, setNote] = useState("")
  const followed = ctx.account.follows.includes(pubkey)
  const readOnly = !!ctx.signer?.readOnly
  const run = (what, fn, done) => async () => {
    if (readOnly) return setNote(READ_ONLY_SHORT)
    setBusy(what); setNote("")
    try { await fn(); setNote(done); setTimeout(onClose, 900) }
    catch (e) { setNote(String(e?.message ?? e)) }
    finally { setBusy("") }
  }
  const follow = run("follow", () => toggleFollow(ctx, pubkey, !followed), followed ? `Unfollowed ${name}` : `Following ${name}`)
  const block = run("block", () => setBlock(ctx, pubkey, { block: true }), `Blocked ${name}`)
  return (
    <div class="quick-menu" role="menu" aria-label={name}>
      <button type="button" role="menuitem" class={followed ? "unfollow" : "follow"} disabled={!!busy || !ctx.account.loaded} onClick={follow}
        aria-label={followed ? `Unfollow ${name}` : `Follow ${name}`} title={followed ? `Unfollow ${name}` : `Follow ${name}`}>
        {busy === "follow" ? <span class="kind-spinner" /> : <Icon d={followed ? PERSON + "M17 11h6" : PERSON + "M20 8v6M17 11h6"} />}
      </button>
      <a role="menuitem" class="wot" href={`#/wot/${pubkey}`} aria-label="Web of Trust" title={`Shows how you're connected to ${name}`} onClick={onClose}>
        <Icon d="M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 10V3.5M13.7 13l5.6 3.5M10.3 13l-5.6 3.5" />
      </a>
      <hr />
      <button type="button" role="menuitem" class="block" disabled={!!busy} onClick={block} aria-label={`Block ${name}`} title={`Block ${name}`}>
        {busy === "block" ? <span class="kind-spinner" /> : <Icon d="M7 11V6a1.5 1.5 0 0 1 3 0v4M10 10V4.5a1.5 1.5 0 0 1 3 0V10M13 10V5.5a1.5 1.5 0 0 1 3 0V11M16 11V8.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-2.7L3.5 15a1.6 1.6 0 0 1 2.6-1.8L7 14.5" />}
      </button>
      {note && <span class="quick-menu-note" role="status">{note}</span>}
    </div>
  )
}

const PERSON = "M9 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21c0-3.9 3.1-7 7-7s7 3.1 7 7"
const Icon = ({ d }) => <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
