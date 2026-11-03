// The left rail's favourites (rail-favs.js) as rows: a section as the rail always drew it, and what was pinned
// beside them (a feed, a person, a hashtag, a list, a relay's feed), each an icon or face with a short name under it.
// Sidebar.jsx puts them between New Post and Settings; RailEdit.jsx edits them.
import { Avatar } from "../../components/Avatar.jsx"
import { useProfile } from "../../components/useProfile.js"
import { FEED_ICON, LIST_ICON } from "../../components/FeedPickerMenu.jsx"
import { feedList } from "../../net/feeds.js"
import { READERS } from "../../readers/index.js"
import { favHref, favKey, relayName } from "./rail-favs.js"
import { Icon, ICON } from "../icons.jsx"

export const FEEDS = feedList(READERS)
export const FEED_IDS = FEEDS.map(f => f.id)
// Each section's name and its shortcut (desktop/keys.js), for the tooltips.
export const SECTION = { feed: ["Feed", "g f"], search: ["Search", "/"], messages: ["Messages", "g m"], wot: ["WoT", "g w"], vault: ["Vault", "g v"], profile: ["Profile", "g p"] }

const shortName = (p, pk) => p?.display_name || p?.name || `${pk.slice(0, 8)}…`

/** A favourite's name in full, for its tooltip and for the edit list. */
export function favTitle(f, profile) {
  switch (f.type) {
    case "section": return SECTION[f.id]?.[0] ?? f.id
    case "feed": return FEEDS.find(x => x.id === f.mode)?.label ?? f.mode
    case "person": return shortName(profile, f.pubkey)
    case "hashtag": return `#${f.tag}`
    case "list": return f.name || f.d
    case "relay": return relayName(f.url)
    default: return f.type
  }
}

/** A favourite's icon (a person shows their face). */
export function FavIcon({ fav, size = 22 }) {
  if (fav.type === "person") return <Avatar pubkey={fav.pubkey} size={size + 4} />
  const d = fav.type === "section" ? ICON[fav.id] : fav.type === "feed" ? FEED_ICON[fav.mode] ?? LIST_ICON
    : fav.type === "hashtag" ? FEED_ICON.hashtag : fav.type === "relay" ? FEED_ICON.relay : LIST_ICON
  return <Icon d={d} size={size === 22 ? 20 : size} />
}

/** One favourite in the rail. `on`: the section shown now. `badge`: unread count for Messages and Vault. */
export function FavRow({ fav, on, badge = 0 }) {
  const p = useProfile(fav.type === "person" ? fav.pubkey : null)
  const title = favTitle(fav, p)
  const keys = fav.type === "section" ? SECTION[fav.id]?.[1] : null
  return (
    <a href={favHref(fav)} class={`${on ? "side-row on" : "side-row"}${fav.type === "section" ? "" : " side-fav"}`} data-fav={favKey(fav)}
      aria-current={on ? "page" : undefined} title={keys ? `${title} (${keys})` : title}
      aria-label={`${title}${badge ? `, ${badge} unread` : ""}`}>
      <span class="side-icon"><FavIcon fav={fav} />{badge > 0 && <span class="side-dot" aria-hidden="true" />}</span>
      <span class="side-label">{title}</span>
    </a>
  )
}
