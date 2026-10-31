// The Web of Trust tab's trust card (TrustWebView+TrustCard): who they are, how they reach you, and Follow, Profile,
// See their web, then Message, Brainstorm and Block or Unblock behind "…". WotScreen.jsx opens it.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { BlockDialog, UnblockDialog } from "../components/Moderation.jsx"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { setFollow } from "../net/follows.js"
import { trustPath, trustPathText } from "../net/wot.js"
import { WOT_GLOBE } from "../components/wot-glyph.js"
import { brainstormLink } from "../net/person.js"

const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
// SF Symbol look-alikes for the card's buttons: person.badge.plus / .minus, person.crop.circle, xmark.
const ICON = {
  follow: "M10 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM3 21v-1a7 7 0 0 1 11-5.7M19 14v6M16 17h6",
  unfollow: "M10 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM3 21v-1a7 7 0 0 1 11-5.7M16 17h6",
  profile: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 13a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM5.5 19a7.5 7.5 0 0 1 13 0",
  close: "M6 6l12 12M18 6 6 18",
}
const CardIcon = ({ d, size = 13 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

/** The trust card (TrustWebView+TrustCard): who they are, the faces of the people you follow who follow them with how
 *  they reach you, and Follow, Profile, See their web, then Message, Brainstorm and Block or Unblock behind "…", in the
 *  iPhone's order. */
export function TrustCard({ ctx, web, built, root, pubkey, onPick, onSeeWeb, onClose }) {
  const { vault, account, session, signer } = ctx
  const [, bump] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [dialog, setDialog] = useState(null) // "block" | "unblock"
  const { blocked } = useBlocks(ctx)
  const isBlocked = blocked.has(pubkey)
  // A blocked person is out of your web; their line is still traced, from the web before blocks.
  const pathWeb = isBlocked ? built : web
  const layer = pathWeb.layerOf(pubkey)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  useEffect(() => {
    setErr("")
    // Your follows' names and pictures are kept; a stranger's stay in memory.
    fetchProfiles(vault, [pubkey], uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: layer === "follow" }).catch(() => {})
  }, [pubkey])
  // Blocking someone puts their card away, as on the iPhone.
  const wasBlocked = useRef(isBlocked)
  useEffect(() => { if (isBlocked && !wasBlocked.current) onClose(); wasBlocked.current = isBlocked }, [isBlocked])
  const iFollow = account.follows.includes(pubkey)
  const isMe = pubkey === session.pubkey
  const toggle = async () => {
    setBusy(true); setErr("")
    try {
      await setFollow({ vault, signer, pubkey: session.pubkey, target: pubkey, follow: !iFollow,
        readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
      await ctx.reloadAccount()
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const p = getProfile(pubkey)
  const bridges = trustPath(pathWeb, pubkey)?.bridges ?? []
  const outside = !layer
  return (
    <section class="wot-card" role="dialog" aria-label={`Trust card: ${nameOf(pubkey)}`}>
      <div class="wot-card-head">
        <Avatar pubkey={pubkey} size={44} ring={isMe} />
        <div class="wot-card-names">
          <div class="wot-card-name"><AuthorName pubkey={pubkey} /></div>
          <div class="wot-card-sub">{p?.nip05?.replace(/^_@/, "") || npubEncode(pubkey).slice(0, 16) + "…"}</div>
        </div>
        <button type="button" class="wot-card-close" aria-label="Close" onClick={onClose}><CardIcon d={ICON.close} size={13} /></button>
      </div>
      {/* The bridges' faces, overlapping, then how they reach you (the trust row). A face opens its own card. */}
      <div class="wot-trust-row">
        {bridges.length > 0 && <span class="wot-bridges" aria-label="Who links you">
          {bridges.map(f => <button key={f} type="button" class="wot-bridge" title={nameOf(f)} aria-label={`Show ${nameOf(f)}`} onClick={() => onPick(f)}><Avatar pubkey={f} size={26} /></button>)}
        </span>}
        <p class={outside ? "wot-path outside" : "wot-path"}>{trustPathText(pathWeb, pubkey, nameOf)}</p>
      </div>
      {!isMe && (
        <div class="wot-actions">
          <button type="button" class={iFollow ? "wot-action" : "wot-action filled"} disabled={busy || !account.loaded} onClick={toggle} aria-busy={busy || undefined}>
            <CardIcon d={iFollow ? ICON.unfollow : ICON.follow} />
            {busy ? (signer.method === "nip46" ? "Waiting…" : "…") : iFollow ? "Unfollow" : "Follow"}
          </button>
          <a class="wot-action" href={`#/profile/${pubkey}`}><CardIcon d={ICON.profile} />Profile</a>
          {/* The iPhone's short label on a narrow card ("Their web"); its full name for screen readers. */}
          {pubkey !== root && <button type="button" class="wot-action" aria-label="See their web" title={`Puts ${nameOf(pubkey)} in the middle, with the people they follow around them`} onClick={() => onSeeWeb(pubkey)}>
            <svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d={WOT_GLOBE} /></svg>Their web
          </button>}
          <CardMore pubkey={pubkey} blocked={isBlocked} onDialog={setDialog} />
        </div>
      )}
      {err && <p class="error small" role="alert">{err}</p>}
      {dialog === "block" && <BlockDialog ctx={ctx} pubkey={pubkey} name={nameOf(pubkey)} onClose={() => setDialog(null)} />}
      {dialog === "unblock" && <UnblockDialog ctx={ctx} pubkey={pubkey} name={nameOf(pubkey)} onClose={() => setDialog(null)} />}
    </section>
  )
}

/** The card's "…": Message, Open in Brainstorm, then Block or Unblock, the iPhone's menu in the note menu's classes. */
function CardMore({ pubkey, blocked, onDialog }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  const pick = fn => () => { setOpen(false); fn() }
  return (
    <span class="more-wrap" ref={ref}>
      <button type="button" class="wot-action wot-more" aria-label="More" title="More" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12h.01M12 12h.01M19 12h.01" /></svg>
      </button>
      {open && (
        <div class="more-menu" role="menu">
          <button role="menuitem" onClick={pick(() => { location.hash = `#/dm/${pubkey}` })}>Message</button>
          <button role="menuitem" onClick={pick(() => open_(brainstormLink(pubkey)))}>Open in Brainstorm</button>
          <hr class="more-sep" />
          {blocked
            ? <button role="menuitem" onClick={pick(() => onDialog("unblock"))}>Unblock</button>
            : <button role="menuitem" class="danger" onClick={pick(() => onDialog("block"))}>Block</button>}
        </div>
      )}
    </span>
  )
}
const open_ = url => globalThis.open(url, "_blank", "noopener,noreferrer")
