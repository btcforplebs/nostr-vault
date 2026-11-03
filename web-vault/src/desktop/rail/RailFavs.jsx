// The left rail's pins (rail-favs.js) as rows: a section as the rail always drew it, and the favourites pinned beside
// them (a person, a hashtag, a people list, a relay's feed), each an icon or face with a short name under it.
// Sidebar.jsx puts them between New Post and Settings; RailEdit.jsx edits them.
import { Avatar } from "../../components/Avatar.jsx"
import { useProfile } from "../../components/useProfile.js"
import { FEED_ICON, LIST_ICON } from "../../components/FeedPickerMenu.jsx"
import { pinHref, pinKey, relayName } from "./rail-favs.js"
import { Icon, ICON } from "../icons.jsx"

// Each drawn section's name and its shortcut (desktop/keys.js), for the tooltips.
export const SECTION = { feed: ["Feed", "g f"], search: ["Search", "/"], messages: ["Messages", "g m"], wot: ["WoT", "g w"], vault: ["Vault", "g v"], profile: ["Profile", "g p"] }
export const KIND_NAME = { person: "Person", hashtag: "Hashtag", list: "List", relay: "Relay" }

/** A pin's name in full, for its tooltip and the edit list. The live name wins over the one saved when it was pinned. */
export function pinTitle(p, profile) {
  switch (p.type) {
    case "section": return SECTION[p.id]?.[0] ?? p.id
    case "person": return profile?.display_name || profile?.name || p.name || `${p.p.slice(0, 8)}…`
    case "hashtag": return `#${p.t}`
    case "list": return p.name || p.a.slice(p.a.indexOf(":", 6) + 1)
    case "relay": return relayName(p.url)
    default: return p.name || p.type
  }
}

/** A pin's icon (a person shows their face). */
export function PinIcon({ pin, size = 20 }) {
  if (pin.type === "person") return <Avatar pubkey={pin.p} size={size + 6} />
  const d = pin.type === "section" ? ICON[pin.id] : pin.type === "hashtag" ? FEED_ICON.hashtag : pin.type === "relay" ? FEED_ICON.relay : LIST_ICON
  return <Icon d={d} size={size} />
}

/** One pin in the rail. `on`: the section shown now. `badge`: unread count for Messages and Vault. */
export function PinRow({ pin, on, badge = 0 }) {
  const profile = useProfile(pin.type === "person" ? pin.p : null)
  const title = pinTitle(pin, profile)
  const keys = pin.type === "section" ? SECTION[pin.id]?.[1] : null
  return (
    <a href={pinHref(pin)} class={`${on ? "side-row on" : "side-row"}${pin.type === "section" ? "" : " side-fav"}`} data-pin={pinKey(pin)}
      aria-current={on ? "page" : undefined} title={keys ? `${title} (${keys})` : title}
      aria-label={`${title}${badge ? `, ${badge} unread` : ""}`}>
      <span class="side-icon"><PinIcon pin={pin} />{badge > 0 && <span class="side-dot" aria-hidden="true" />}</span>
      <span class="side-label">{title}</span>
    </a>
  )
}
