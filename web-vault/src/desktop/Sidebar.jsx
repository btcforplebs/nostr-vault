// The desktop's sections as the iPad's slim rail down the left edge (Logen, 2026-11-03: the web takes its cues from the
// iPad; the top bar it had since 2026-11-02 is gone). Top to bottom: the account picture (a tap lists the accounts on
// this browser, one more tap switches), New Post, then the favourites: Feed, Search, Messages, WoT, Vault and Profile
// by default, each an icon with its name under it (BottomTabBar's vertical sidebar), plus whatever the user pinned
// and in the user's order (rail/rail-favs.js, edited in rail/RailEdit.jsx, synced with Your space's layout). At the
// foot Settings, Learn, Docs and the vault's status dot. desktop.css lays it out.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { badgeCount, useUnreadTotal } from "../components/useUnreadTotal.js"
import { useVaultUnread } from "../components/useVaultUnread.js"
import { learn } from "../shell.js"
import { resetBrowser } from "../screens/SettingsScreen.jsx"
import { Icon, ICON } from "./icons.jsx"
import { methodLabel } from "../screens/SignInScreen.jsx"
import { loadAccounts } from "../session.js"
import { switchAccount } from "../signer/accounts.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { useLayout } from "./space/layout-store.js"
import { shownPins, pinKey, webHasFeedPin } from "./rail/rail-favs.js"
import { PinRow } from "./rail/RailFavs.jsx"
import { RailEdit } from "./rail/RailEdit.jsx"

export { Icon, ICON } from "./icons.jsx"

const PIN = "M9 4h6l-1 6 3 3H7l3-3zM12 13v7"

export function Sidebar({ ctx, side, rail }) {
  const readOnly = ctx.signer?.readOnly
  const unread = useUnreadTotal(ctx)
  const vaultNew = useVaultUnread() // unread Vault lines: a dot on Vault (the iPhone's vaultHasNews)
  // badge: a count after the name (iPadSidebarView's red capsule); on the rail, where names hide, a dot on the icon.
  const row = (id, label, keys, badge = 0) => (
    <a key={id} href={`#/${id}`} class={side === id ? "side-row on" : "side-row"} aria-current={side === id ? "page" : undefined}
      title={rail ? `${label} (${keys})` : `${keys}`} aria-label={rail || badge ? `${label}${badge ? `, ${badge} unread` : ""}` : undefined}>
      <span class="side-icon"><Icon d={ICON[id]} />{badge > 0 && rail && <span class="side-dot" aria-hidden="true" />}</span>
      <span class="side-label">{label}</span>
      {badge > 0 && !rail && <span class="side-badge" aria-hidden="true">{badgeCount(badge)}</span>}
    </a>
  )
  const [layout, change] = useLayout(ctx.session.pubkey)
  const [editing, setEditing] = useState(false)
  const pins = shownPins(layout.pins)
  // Pinned people's names and faces.
  const people = pins.filter(p => p.type === "person").map(p => p.p).join()
  useEffect(() => {
    if (people) fetchProfiles(ctx.vault, people.split(","), uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {})
  }, [people])
  return (
    <nav class="desk-side" aria-label="Sections">
      <AccountButton ctx={ctx} rail={rail} />
      {readOnly
        ? <span class="side-row side-post off" aria-disabled="true" title={`New Post. ${READ_ONLY_SHORT}`}><Icon d={ICON.post} /><span class="side-label">New Post</span></span>
        : <a class="side-row side-post" href="#/compose" title={rail ? "New Post (n)" : "n"} aria-label={rail ? "New Post" : undefined}><Icon d={ICON.post} /><span class="side-label">New Post</span></a>}
      <hr />
      {pins.filter(webHasFeedPin).map(p => <PinRow key={pinKey(p)} pin={p} on={p.type === "section" && side === p.id}
        badge={p.type === "section" ? (p.id === "messages" ? unread : p.id === "vault" ? vaultNew : 0) : 0} />)}
      <button type="button" class={editing ? "side-row side-edit-btn on" : "side-row side-edit-btn"} aria-expanded={editing}
        title="Pin, reorder or take off what's on the rail" aria-label="Edit the rail" onClick={() => setEditing(!editing)}>
        <span class="side-icon"><Icon d={PIN} size={18} /></span><span class="side-label">Edit</span>
      </button>
      {editing && <RailEdit ctx={ctx} layout={layout} change={change} onClose={() => setEditing(false)} />}
      <span class="side-gap" aria-hidden="true" />
      {row("settings", "Settings", "g ,")}
      <HelpRows rail={rail} />
      <RelayFoot ctx={ctx} rail={rail} />
    </nav>
  )
}

/** Learn (the marketing page around the app, src/shell.js; the app keeps its place) and Docs (nostrvault.app/docs/,
 *  in a new tab, since leaving the page would stop the in-page relay). */
function HelpRows({ rail }) {
  return (<>
    <a class="side-row" href="/#about" title={rail ? "Learn" : undefined} aria-label={rail ? "Learn" : undefined}
      onClick={e => { e.preventDefault(); learn() }}>
      <span class="side-icon"><Icon d={ICON.learn} /></span><span class="side-label">Learn</span>
    </a>
    <a class="side-row" href="/docs/" target="_blank" rel="noopener" title={rail ? "Docs (opens a new tab)" : "Opens a new tab"}
      aria-label={rail ? "Docs, opens a new tab" : undefined}>
      <span class="side-icon"><Icon d={ICON.docs} /></span><span class="side-label">Docs</span>
    </a>
  </>)
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
          <span class="side-account-kind">{signer?.readOnly ? "Read-only" : methodLabel(session)}</span>
        </span>
        <span class="side-label side-chevron"><Icon d={ICON.chevron} size={14} /></span>
      </button>
      {open && (
        <div class="side-pop" role="menu" onClick={e => { if (e.target.closest("[role=menuitem]")) setOpen(false) }}>
          <SwitchRows ctx={ctx} />
          <a role="menuitem" href="#/accounts">Add or manage accounts</a>
          <a role="menuitem" href="#/wallet">Wallet</a>
          <hr />
          <button role="menuitem" type="button" class="danger" onClick={() => resetBrowser(ctx)}>Sign out</button>
        </div>
      )}
    </div>
  )
}

/** The accounts on this browser, as the iPhone's Switch Account menu: the one signed in ticked, a tap on another
 *  reloads into it. */
function SwitchRows({ ctx }) {
  const [err, setErr] = useState("")
  const accounts = loadAccounts()
  // Signed in with no saved account list (a read-only look): just this one.
  if (!accounts.some(a => a.pubkey === ctx.session.pubkey)) accounts.unshift({ pubkey: ctx.session.pubkey })
  const go = async (e, account) => {
    e.stopPropagation() // keep the menu open: a switch reloads, a refused one shows why here
    setErr("")
    try { await switchAccount({ account, vault: ctx.vault, signer: ctx.signer }) } catch (x) { setErr(String(x?.message ?? x)) }
  }
  return (<>
    <p class="side-pop-title" aria-hidden="true">{accounts.length > 1 ? "Switch Account" : "Account"}</p>
    {accounts.map(a => a.pubkey === ctx.session.pubkey
      ? <span key={a.pubkey} role="menuitemradio" aria-checked="true" class="side-switch on"><Avatar pubkey={a.pubkey} size={22} /><SwitchName account={a} /></span>
      : <button key={a.pubkey} role="menuitemradio" aria-checked="false" type="button" class="side-switch" onClick={e => go(e, a)}><Avatar pubkey={a.pubkey} size={22} /><SwitchName account={a} /></button>)}
    {err && <p class="side-pop-error" role="alert">{err}</p>}
    <hr />
  </>)
}
const SwitchName = ({ account }) => {
  const p = useProfile(account.pubkey)
  return <span class="side-switch-name">{p?.display_name || p?.name || npubEncode(account.pubkey).slice(0, 12) + "…"}</span>
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
      <a class="side-relay" href="#/relay" title={rail ? `Vault: ${state}${count != null ? ` · ${count.toLocaleString()} events` : ""}` : "Vault Dashboard"} aria-label={`Vault ${state}`}>
        <span class={online ? "dot on" : "dot booting"} />
        <span class="side-label">{state}</span>
      </a>
      <div class="side-label side-relay-row">
        <span class="muted small">{count == null ? "…" : `${count.toLocaleString()} events`}</span>
        <button type="button" class="small side-restart" title="Reload the page, which restarts your vault" onClick={() => location.reload()}>Restart</button>
      </div>
    </div>
  )
}
