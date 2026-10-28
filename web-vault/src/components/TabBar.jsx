import { Avatar } from "./Avatar.jsx"
import { useUnreadTotal } from "./useUnreadTotal.js"
import { useVaultUnread } from "./useVaultUnread.js"
import { useEffect, useState } from "preact/hooks"
import { isFolded, onFoldedChange, unfold } from "./chrome-fold.js"
import "../styles/tabbar.css"
import "../styles/chrome-fold.css"

// The phone's five tabs, in its order: Feed · Search · Profile · WoT · Vault (iPhone BottomTabBar). Everything else
// is reached the way the phone reaches it, from a floating button at the top of a tab: Messages and the Vault
// Dashboard from the Vault tab, Settings and the Wallet from Profile. Compose is the floating Post button.
// The iPhone's icons (BottomTabBar): SF Symbols person.2.wave.2, magnifyingglass and lock.rectangle.stack, drawn on a
// 24 grid at the symbols' regular weight, and the WoT tab's own globe (Assets WoTTab, wot_tab.svg), which the phone
// draws at 26 so its circle reads as tall as the Vault box.
const line = d => <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{d}</svg>
/** The WoT tab's globe, filled: wot_tab.svg as the iPhone ships it. */
export const WOT_GLOBE = "M22 12.000C22 17.523 17.523 22 12 22.000C6.477 22 2 17.523 2 12.000C2 6.477 6.477 2 12 2.000C17.523 2 22 6.477 22 12.000ZM8.824 8.811C8.508 8.327 8.051 7.944 7.510 7.721C7.828 6.285 8.313 5.039 8.925 4.082C6.883 4.870 5.223 6.427 4.304 8.400C3.805 8.919 3.500 9.624 3.500 10.400C3.500 10.607 3.522 10.810 3.564 11.005C3.520 11.330 3.500 11.663 3.500 12.000C3.500 15.609 5.749 18.692 8.925 19.918C7.906 18.324 7.239 15.931 7.096 13.212C7.481 13.121 7.835 12.950 8.139 12.717L8.569 12.840C8.754 17.178 10.361 20.500 12 20.500C12.132 20.500 12.264 20.478 12.395 20.436C12.810 20.668 13.290 20.800 13.800 20.800C14.894 20.800 15.847 20.194 16.340 19.299C18.833 17.825 20.500 15.107 20.500 12.000C20.500 10.688 20.203 9.446 19.666 8.342C19.817 7.991 19.900 7.605 19.900 7.200C19.900 5.598 18.602 4.300 17 4.300C16.637 4.300 16.290 4.367 15.971 4.491C15.682 4.338 15.383 4.201 15.075 4.082C15.208 4.291 15.335 4.513 15.456 4.749C14.986 5.042 14.608 5.467 14.375 5.974C13.733 4.438 12.871 3.500 12 3.500C10.673 3.500 9.368 5.676 8.824 8.811ZM18.800 7.200C18.800 8.194 17.994 9 17 9.000C16.728 9 16.471 8.940 16.240 8.830L14.041 10.942C14.207 11.258 14.300 11.618 14.300 12.000C14.300 12.803 13.889 13.509 13.265 13.920L13.932 16.107C14.865 16.173 15.600 16.951 15.600 17.900C15.600 18.894 14.794 19.700 13.800 19.700C12.806 19.700 12 18.894 12 17.900C12 17.326 12.269 16.814 12.689 16.486L12.022 14.299C12.015 14.300 12.007 14.300 12 14.300C10.736 14.300 9.710 13.281 9.701 12.019L7.833 11.486C7.506 11.920 6.986 12.200 6.400 12.200C5.406 12.200 4.600 11.394 4.600 10.400C4.600 9.406 5.406 8.600 6.400 8.600C7.339 8.600 8.110 9.319 8.192 10.236L10.059 10.769C10.465 10.126 11.183 9.700 12 9.700C12.415 9.700 12.805 9.810 13.140 10.004L15.339 7.894C15.249 7.680 15.200 7.446 15.200 7.200C15.200 6.206 16.006 5.400 17 5.400C17.994 5.400 18.800 6.206 18.800 7.200ZM16.861 10.093C16.921 10.709 16.950 11.348 16.950 12.000C16.950 13.670 16.759 15.251 16.407 16.636C16.140 16.079 15.698 15.622 15.152 15.335C15.343 14.317 15.450 13.189 15.450 12.000C15.450 11.707 15.443 11.417 15.431 11.132L16.547 10.061C16.649 10.081 16.754 10.092 16.861 10.093Z"
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
  return (
    <nav class="tabbar" aria-label="Sections">
      <div class="tabs-full" inert={folded || undefined}>
        {TABS.map(([id, label]) => (
          <a key={id} href={`#/${id}`} class={route === id ? "tab on" : "tab"} aria-current={route === id ? "page" : undefined}
            aria-label={id === "vault" && news ? `${label}, ${unread ? `${unread} unread` : "new activity"}` : undefined} onClick={id === "feed" && route === "feed" ? retapFeed : undefined}>
            {id === "profile" && pubkey
              ? <span class="tab-avatar"><Avatar pubkey={pubkey} size={24} /></span>
              : <span class="tab-icon">{ICONS[id] ?? line(<path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0" />)}</span>}
            {id === "vault" && news && <span class="tab-dot" aria-hidden="true" />}
            <span>{label}</span>
          </a>
        ))}
      </div>
      <FoldedBar route={route} pubkey={pubkey} unread={unread} news={news} canPost={!ctx.signer?.readOnly} inert={!folded} />
    </nav>
  )
}

/** Scrolled down, the bar folds to this (chrome-fold.js, BottomTabBar collapsedContent): the avatar, which opens the bar
 *  again, and one round button, Compose, or on the Vault tab the Vault Dashboard. */
function FoldedBar({ route, pubkey, unread, news, canPost, inert }) {
  const vault = route === "vault"
  return (
    <div class="tabs-fold" inert={inert || undefined}>
      <button type="button" class="fold-avatar" aria-label={unread ? `Show the tab bar, ${unread} unread` : "Show the tab bar"} onClick={unfold}>
        <Avatar pubkey={pubkey} size={36} />
        {news && <span class="tab-dot" aria-hidden="true" />}
      </button>
      {(vault || canPost) && <a class={vault ? "fold-action vault" : "fold-action"} href={vault ? "#/relay" : "#/compose"} aria-label={vault ? "Vault Dashboard" : "Compose new post"}>
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
