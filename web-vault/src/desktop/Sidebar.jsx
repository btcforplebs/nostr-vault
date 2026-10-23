// The desktop sidebar (design §2), in the iPad sidebar's order: account, New Post, Messages, then the sections, then
// the relay's status at the foot. At 1024–1279px (or folded with "[") it is a 64px rail of icons with tooltips.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { badgeCount, useUnreadTotal } from "../components/useUnreadTotal.js"
import { learn } from "../shell.js"

const ICON = {
  post: "M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z",
  messages: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM3 7l9 6 9-6",
  feed: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8",
  search: "M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.8-4.8",
  profile: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0",
  wot: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 10V3.5M13.7 13l5.6 3.5M10.3 13l-5.6 3.5",
  vault: "M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM12 13.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 11v2M4 9h3M4 15h3",
  settings: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4",
  chevron: "M6 9l6 6 6-6",
}
export const Icon = ({ d, size = 20 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

const SECTIONS = [["feed", "Feed", "g f"], ["search", "Search", "/"], ["profile", "Profile", "g p"], ["wot", "WoT", "g w"], ["vault", "Vault", "g v"], ["settings", "Settings", "g ,"]]

export function Sidebar({ ctx, side, rail }) {
  const readOnly = ctx.signer?.readOnly
  const unread = useUnreadTotal(ctx)
  // badge: a count after the name (iPadSidebarView's red capsule); on the rail, where names hide, a dot on the icon.
  const row = (id, label, keys, badge = 0) => (
    <a key={id} href={`#/${id}`} class={side === id ? "side-row on" : "side-row"} aria-current={side === id ? "page" : undefined}
      title={rail ? `${label} (${keys})` : `${keys}`} aria-label={rail || badge ? `${label}${badge ? `, ${badge} unread` : ""}` : undefined}>
      <span class="side-icon"><Icon d={ICON[id]} />{badge > 0 && rail && <span class="side-dot" aria-hidden="true" />}</span>
      <span class="side-label">{label}</span>
      {badge > 0 && !rail && <span class="side-badge" aria-hidden="true">{badgeCount(badge)}</span>}
    </a>
  )
  return (
    <nav class="desk-side" aria-label="Sections">
      <AccountButton ctx={ctx} rail={rail} />
      {readOnly
        ? <span class="side-row side-post off" aria-disabled="true" title={`New Post. ${READ_ONLY_SHORT}`}><Icon d={ICON.post} /><span class="side-label">New Post</span></span>
        : <a class="side-row side-post" href="#/compose" title={rail ? "New Post (n)" : "n"} aria-label={rail ? "New Post" : undefined}><Icon d={ICON.post} /><span class="side-label">New Post</span></a>}
      {row("messages", "Messages", "g m", unread)}
      <hr />
      {SECTIONS.map(([id, label, keys]) => row(id, label, keys))}
      <RelayFoot ctx={ctx} rail={rail} />
    </nav>
  )
}

/** Avatar, name and key kind; a click opens Accounts, Wallet and Sign out (Wallet moved here from the Profile banner). */
function AccountButton({ ctx, rail }) {
  const { session, signer } = ctx
  const p = useProfile(session.pubkey)
  const [open, setOpen] = useState(false)
  const ref = useRef()
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") { e.preventDefault(); setOpen(false) } }
    addEventListener("pointerdown", away); addEventListener("keydown", key, true)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key, true) }
  }, [open])
  const name = p?.display_name || p?.name || npubEncode(session.pubkey).slice(0, 12) + "…"
  return (
    <div class="side-account" ref={ref}>
      <button type="button" class="side-account-btn" aria-haspopup="menu" aria-expanded={open} aria-label={`Account: ${name}`} title={rail ? name : undefined} onClick={() => setOpen(!open)}>
        <Avatar pubkey={session.pubkey} size={rail ? 36 : 32} />
        <span class="side-label side-account-names">
          <span class="side-account-name">{name}</span>
          <span class="side-account-kind">{signer?.readOnly ? "Read-only" : "Owner key"}</span>
        </span>
        <span class="side-label side-chevron"><Icon d={ICON.chevron} size={14} /></span>
      </button>
      {open && (
        <div class="side-pop" role="menu" onClick={e => { if (e.target.closest("[role=menuitem]")) setOpen(false) }}>
          <a role="menuitem" href="#/accounts">Accounts</a>
          <a role="menuitem" href="#/wallet">Wallet</a>
          <a role="menuitem" href="/#about" onClick={e => { e.preventDefault(); learn() }}>Learn &amp; docs</a>
          <hr />
          <button role="menuitem" type="button" class="danger" onClick={ctx.signOut}>Sign out</button>
        </div>
      )}
    </div>
  )
}

/** The in-page relay's status and event count; Restart reloads the page, which restarts the relay. */
function RelayFoot({ ctx, rail }) {
  const { vault, session } = ctx
  const [count, setCount] = useState(null)
  const [online, setOnline] = useState(navigator.onLine)
  const follows = useRef(ctx.account.follows)
  follows.current = ctx.account.follows
  useEffect(() => {
    let live = true
    const tick = async () => {
      const [own, feed] = await Promise.all([
        vault.outbox.count({ authors: [session.pubkey] }).catch(() => 0),
        follows.current.length ? vault.feed.count({ kinds: [1, 6], authors: follows.current }).catch(() => 0) : 0,
      ])
      if (live) setCount((Number(own) || 0) + (Number(feed) || 0))
    }
    tick()
    const t = setInterval(tick, 15_000)
    const net = () => setOnline(navigator.onLine)
    addEventListener("online", net); addEventListener("offline", net)
    return () => { live = false; clearInterval(t); removeEventListener("online", net); removeEventListener("offline", net) }
  }, [])
  const state = online ? "Running" : "Running · offline"
  return (
    <div class="side-foot">
      <a class="side-relay" href="#/relay" title={rail ? `Relay: ${state}${count != null ? ` · ${count.toLocaleString()} events` : ""}` : "Vault Dashboard"} aria-label={`Relay ${state}`}>
        <span class={online ? "dot on" : "dot booting"} />
        <span class="side-label">{state}</span>
      </a>
      <div class="side-label side-relay-row">
        <span class="muted small">{count == null ? "…" : `${count.toLocaleString()} events`}</span>
        <button type="button" class="small side-restart" title="Reload the page, which restarts your relay" onClick={() => location.reload()}>Restart</button>
      </div>
    </div>
  )
}
