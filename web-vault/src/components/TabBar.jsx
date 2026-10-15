import { Avatar } from "./Avatar.jsx"

// The phone's five tabs, in its order: Feed · Search · Profile · WoT · Vault (iPhone BottomTabBar). Everything else
// is reached the way the phone reaches it, from a floating button at the top of a tab: Messages and the Vault
// Dashboard from the Vault tab, Settings and the Wallet from Profile. Compose is the floating Post button.
const TABS = [
  ["feed", "Feed", "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8"],
  ["search", "Search", "M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.8-4.8"],
  ["profile", "Profile", null],
  ["wot", "WoT", "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 10V3.5M13.7 13l5.6 3.5M10.3 13l-5.6 3.5"],
  ["vault", "Vault", "M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM12 13.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 11v2M4 9h3M4 15h3"],
]

/** Floating glass capsule. `pubkey` puts the user's avatar on the Profile tab (falls back to a person glyph). */
export function TabBar({ route, pubkey }) {
  return (
    <nav class="tabbar" aria-label="Sections">
      {TABS.map(([id, label, d]) => (
        <a key={id} href={`#/${id}`} class={route === id ? "tab on" : "tab"} aria-current={route === id ? "page" : undefined}>
          {id === "profile" && pubkey
            ? <span class="tab-avatar"><Avatar pubkey={pubkey} size={26} /></span>
            : <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d || "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0"} /></svg>}
          <span>{label}</span>
        </a>
      ))}
    </nav>
  )
}

/** The orange floating Post button (iOS FeedView), one row above the tab bar. Opens #/compose. */
export function PostButton() {
  return (
    <a class="post-button" href="#/compose">
      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z" /></svg>
      Post
    </a>
  )
}
