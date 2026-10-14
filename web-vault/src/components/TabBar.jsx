import { Avatar } from "./Avatar.jsx"

// Feed · Search · Messages · Notifications · Profile · Relay. Compose is the floating Post button, as on iOS, not a tab.
const TABS = [
  ["feed", "Feed", "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8"],
  ["search", "Search", "M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.8-4.8"],
  ["messages", "Messages", "M4 5h16a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H9l-4.5 3.5V16H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"],
  ["notifications", "Alerts", "M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5a2 2 0 0 0 4 0"],
  ["profile", "Profile", null],
  ["relay", "Relay", "M4.9 19.1a10 10 0 0 1 0-14.2M19.1 4.9a10 10 0 0 1 0 14.2M7.8 16.2a6 6 0 0 1 0-8.4M16.2 7.8a6 6 0 0 1 0 8.4M12 13.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3z"],
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
