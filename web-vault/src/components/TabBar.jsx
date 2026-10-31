import { Avatar } from "./Avatar.jsx"
import { useUnreadTotal } from "./useUnreadTotal.js"
import { useVaultUnread } from "./useVaultUnread.js"
import { dashboardHref, openDashboard } from "../net/dashboard-route.js"
import { useEffect, useState } from "preact/hooks"
import { isFolded, onFoldedChange, unfold } from "./chrome-fold.js"
import { useAccountSwitch } from "./AccountSwitch.jsx"
import { WOT_GLOBE } from "./wot-glyph.js"
import "../styles/tabbar.css"
import "../styles/chrome-fold.css"

// The phone's five tabs, in its order: Feed · Search · Profile · WoT · Vault (iPhone BottomTabBar). Everything else
// is reached the way the phone reaches it, from a floating button at the top of a tab: Messages and the Vault
// Dashboard from the Vault tab, Settings and the Wallet from Profile. Compose is the floating Post button.
// The iPhone's icons (BottomTabBar): SF Symbols person.2.wave.2, magnifyingglass and lock.rectangle.stack, drawn on a
// 24 grid at the symbols' regular weight, and the WoT tab's own globe (Assets WoTTab, wot_tab.svg), which the phone
// draws at 26 so its circle reads as tall as the Vault box.
const line = d => <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{d}</svg>
const ICONS = {
  feed: line(<>
    <circle cx="6.3" cy="10.2" r="2.3" /><path d="M1.8 19.6c.2-2.6 2.1-4.3 4.5-4.3 1 0 1.9.3 2.6.8M1.8 19.6h4.6" />
    <circle cx="12.4" cy="9.4" r="2.8" /><path d="M7.2 19.6c.2-3.2 2.4-5.4 5.2-5.4s5 2.2 5.2 5.4z" />
    <path d="M17.4 6.4a4.6 4.6 0 0 1 0 6M19.9 4.6a8 8 0 0 1 0 9.6" />
  </>),
  search: line(<><circle cx="10.2" cy="10.2" r="6.6" /><path d="M15 15l5.5 5.5" /></>),
  wot: <svg viewBox="0 0 24 24" width="26" height="26" fill="currentColor" aria-hidden="true"><path d={WOT_GLOBE} /></svg>,
  vault: line(<>
    <path d="M7.4 3.2h9.2M5.8 5.6h12.4" />
    <rect x="3.8" y="8" width="16.4" height="13" rx="3.4" />
    <path d="M10.4 13.6v-1.2a1.6 1.6 0 0 1 3.2 0v1.2" /><rect x="9.4" y="13.4" width="5.2" height="4.2" rx="1" fill="currentColor" stroke="none" />
  </>),
}
const TABS = [["feed", "Feed"], ["search", "Search"], ["profile", "Profile"], ["wot", "WoT"], ["vault", "Vault"]]

/** Floating glass capsule. `pubkey` puts the user's avatar on the Profile tab (falls back to a person glyph). The Vault
 *  tab wears a red dot while a message or a Vault line is unread, as the iPhone's does (BottomTabBar vaultHasNews). */
export function TabBar({ ctx, route, pubkey }) {
  const unread = useUnreadTotal(ctx)
  const vaultNew = useVaultUnread()
  const news = unread > 0 || vaultNew > 0
  const folded = useFolded()
  // Hold the avatar (the Profile tab, or the folded bar's) for Switch Account, as on the iPhone.
  const { holdProps, menu } = useAccountSwitch(ctx)
  return (
    <nav class="tabbar" aria-label="Sections">
      <div class="tabs-full" inert={folded || undefined}>
        {TABS.map(([id, label]) => (
          <a key={id} href={`#/${id}`} class={route === id ? "tab on" : "tab"} aria-current={route === id ? "page" : undefined}
            aria-label={id === "vault" && news ? `${label}, ${unread ? `${unread} unread` : "new activity"}` : undefined} onClick={id === "feed" && route === "feed" ? retapFeed : undefined}
            {...(id === "profile" ? { ...holdProps, class: `${route === id ? "tab on" : "tab"} tab-avatar-hold` } : {})}>
            {id === "profile" && pubkey
              ? <span class="tab-avatar"><Avatar pubkey={pubkey} size={24} /></span>
              : <span class="tab-icon">{ICONS[id] ?? line(<path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0" />)}</span>}
            {id === "vault" && news && <span class="tab-dot" aria-hidden="true" />}
            <span>{label}</span>
          </a>
        ))}
      </div>
      <FoldedBar route={route} pubkey={pubkey} unread={unread} news={news} canPost={!ctx.signer?.readOnly} inert={!folded} holdProps={holdProps} />
      {menu}
    </nav>
  )
}

/** Scrolled down, the bar folds to this (chrome-fold.js, BottomTabBar collapsedContent): the avatar, which opens the bar
 *  again, and one round button, Compose, or on the Vault tab the Vault Dashboard. */
function FoldedBar({ route, pubkey, unread, news, canPost, inert, holdProps }) {
  const vault = route === "vault"
  return (
    <div class="tabs-fold" inert={inert || undefined}>
      <button type="button" class="fold-avatar tab-avatar-hold" aria-label={unread ? `Show the tab bar, ${unread} unread` : "Show the tab bar"} onClick={unfold} {...holdProps}>
        <Avatar pubkey={pubkey} size={36} />
        {news && <span class="tab-dot" aria-hidden="true" />}
      </button>
      {(vault || canPost) && <a class={vault ? "fold-action vault" : "fold-action"} href={vault ? dashboardHref() : "#/compose"} aria-label={vault ? "Vault Dashboard" : "Compose new post"}
        onClick={vault ? e => { e.preventDefault(); openDashboard() } : undefined}>
        {vault ? ICONS.vault : <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={PENCIL} /></svg>}
      </a>}
    </div>
  )
}

/** Re-renders only when the fold crosses halfway, not every frame. */
function useFolded() {
  const [folded, setFolded] = useState(isFolded)
  useEffect(() => onFoldedChange(setFolded), [])
  return folded
}

/** Feed tapped while on the Feed, as on the iPhone: back to the top, and from the top, a refresh (FeedScreen listens). */
function retapFeed(e) {
  e.preventDefault()
  if (scrollY > 0) scrollTo({ top: 0, behavior: "smooth" })
  else dispatchEvent(new Event("nv:feed-refresh"))
}

const PENCIL = "M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"

/** The orange floating Post button (iOS FeedView, SearchView, MyProfileView postButton), in the row just above the tab
 *  bar at the right. Opens #/compose. */
export function PostButton() {
  return (
    <a class="post-button" href="#/compose">
      <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={PENCIL} /></svg>
      Post
    </a>
  )
}
