// The Feed's header, as on the iPhone (Views/Feed/FeedPickerMenu.swift, FeedView+Toolbar.swift): on the left one glass
// pill, the feed's icon + name + chevron, that opens the list of feeds; on the right one glass capsule with the layout
// button, then the Auto-load, Reposts and Replies toggles. Refresh stays for mouse users (no pull to refresh there).
import { AUDIENCES } from "../net/popular.js"
import { useEffect, useRef, useState } from "preact/hooks"
import { LAYOUT_NAME, nextLayout } from "../net/feed-layout.js"

// SF Symbol look-alikes for FeedMode.icon (Services/FeedServiceTypes.swift).
export const FEED_ICON = {
  following: "M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21v-1a6 6 0 0 1 12 0v1M16 3.1a4 4 0 0 1 0 7.8M22 21v-1a6 6 0 0 0-4-5.6",
  discovery: "M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z",
  global: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18",
  hashtag: "M4 9h16M4 15h16M10 3 8 21M16 3l-2 18",
  popular: "M12 22c4 0 7-3 7-7 0-5-5-7-5-12-3 2-5 5-5 8-1-1-2-2-2-4-2 2-2 5-2 8 0 4 3 7 7 7z",
  media: "M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15 9h.01",
  articles: "M6 2h9l5 5v15H6zM14 2v6h6M9 13h8M9 17h8",
  recipes: "M7 2v20M4 2v6a3 3 0 0 0 6 0V2M17 2c-2 0-3 3-3 7h3v13",
  marketplace: "M5 8h14l-1 13H6zM9 8V6a3 3 0 0 1 6 0v2",
  live: "M12 12h.01M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8",
  music: "M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z",
  relay: "M4 4h16v6H4zM4 14h16v6H4zM8 7h.01M8 17h.01",
  polls: "M5 20V11M12 20V4M19 20v-7M3 20h18", // chart.bar
  reels: "M3 5h18v14H3zM10 9l5 3-5 3z", // play.rectangle
}
export const LIST_ICON = "M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"
// Your network's day (the iPhone's square.grid.2x2).
const DASHBOARD_ICON = "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z"
const EDIT_ICON = "M4 6h10M4 12h7M4 18h10M18 5v14M15 16l3 3 3-3M15 8l3-3 3 3" // arrow.up.arrow.down + list
const LAYOUT_ICON = {
  expanded: "M4 4h16v7H4zM4 14h16v6H4z",
  condensed: "M4 5h16M4 10h16M4 15h16M4 20h16",
  threaded: "M4 5h.01M8 5h12M8 10h.01M12 10h8M8 15h.01M12 15h8M4 20h.01M8 20h12",
}
const TOGGLE_ICON = {
  reposts: "M17 2l3 3-3 3M4 11V9a4 4 0 0 1 4-4h12M7 22l-3-3 3-3M20 13v2a4 4 0 0 1-4 4H4",
  replies: "M21 11.5a8.4 8.4 0 0 1-9 8.4 8.6 8.6 0 0 1-3.8-.9L3 21l1.9-5.2A8.4 8.4 0 0 1 12 3.5a8.4 8.4 0 0 1 9 8z",
}
// Media's scope buttons (FeedView+Toolbar.swift): person.2(.fill) and globe.
const SCOPE_ICON = { following: FEED_ICON.following, global: FEED_ICON.global }
const SCOPE_NAME = { following: "Following", global: "Global" }
const TOGGLE_NAME = { reposts: "Reposts", replies: "Replies" }
// Global's shield (iPhone checkmark.shield / shield.slash) and Popular's flame (flame / flame.fill).
const SHIELD = { trust: "M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6zM9 12l2 2 4-4", everyone: "M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6zM4 4l16 16", locked: "M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6zM10 11V9.5a2 2 0 0 1 4 0V11M9 11h6v4H9z" }
const FLAME = "M12 22c4 0 7-3 7-7 0-5-5-7-5-12-3 2-5 5-5 8-1-1-2-2-2-4-2 2-2 5-2 8 0 4 3 7 7 7z"

export const Icon = ({ d, size = 18 }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
    stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
)

/** Closes a popup on a tap outside `ref` or on Escape, while `open`. */
function useDismiss(open, setOpen, ref) {
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const esc = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [open])
}

/** The left pill: icon + name + chevron; it opens the feeds. `feeds`: [{ id, label }] in the picker's order.
 *  `onEdit` opens Edit Feeds, the list's last item as on the iPhone; `onDashboard` the Feed Dashboard, just above it. */
export function FeedModeMenu({ feeds, choice, onPick, onEdit, onDashboard }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useDismiss(open, setOpen, ref)
  // A relay's or a list's feed (a rail favourite) isn't in the picker: it carries its own name.
  const label = choice.mode === "hashtag" && choice.tag ? `#${choice.tag}` : feeds.find(f => f.id === choice.mode)?.label ?? choice.label ?? "Feed"
  return (
    <div class="feed-mode-menu" ref={ref}>
      <button type="button" class="feed-mode-pill" aria-haspopup="menu" aria-expanded={open} aria-label={`Feed: ${label}`}
        onClick={() => setOpen(!open)}>
        <span class="feed-mode-icon"><Icon d={FEED_ICON[choice.mode] ?? LIST_ICON} /></span>
        <span class="feed-mode-name">{label}</span>
        <svg class="feed-mode-chevron" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3"
          stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
      </button>
      {open && <div class="feed-mode-list" role="menu" aria-label="Feeds">
        {feeds.map(f => (
          <button key={f.id} type="button" role="menuitemradio" aria-checked={choice.mode === f.id} class={choice.mode === f.id ? "on" : ""}
            onClick={() => { setOpen(false); onPick({ mode: f.id, tag: choice.tag }) }}>
            <Icon d={FEED_ICON[f.id] ?? LIST_ICON} size={17} /><span>{f.label}</span>
            <span class="check" aria-hidden="true">{choice.mode === f.id ? "✓" : ""}</span>
          </button>
        ))}
        {(onEdit || onDashboard) && <span class="feed-mode-sep" role="separator" />}
        {onDashboard && <button type="button" role="menuitem" class="feed-mode-edit feed-mode-dashboard" onClick={() => { setOpen(false); onDashboard() }}>
          <Icon d={DASHBOARD_ICON} size={17} /><span>Dashboard</span><span class="check" aria-hidden="true" />
        </button>}
        {onEdit && <>
          <button type="button" role="menuitem" class="feed-mode-edit" onClick={() => { setOpen(false); onEdit() }}>
            <Icon d={EDIT_ICON} size={17} /><span>Edit Feeds</span><span class="check" aria-hidden="true" />
          </button>
        </>}
      </div>}
    </div>
  )
}

/** The right capsule. `layout`: null when this feed has one layout. `toggles`: which filters this feed offers.
 *  No Refresh: new notes come in on their own. `scope`: Media's "following" | "global", null elsewhere; `onScope(scope)` picks one. */
/** `shield` ({ everyone, locked }): Global's Web of Trust / Everyone button. `audience` ("all" | "follows" |
 *  "nonFollows") and `ranks` (boolean): Popular's audience menu and rank line switch. Null leaves each out. */
export function FeedToolbar({ layout, onCycleLayout, filters, onFilters, toggles = [], scope = null, onScope, shield = null, onShield, audience = null, onAudience, ranks = null, onRanks }) {
  const next = layout && LAYOUT_NAME[nextLayout(layout)]
  const flip = k => onFilters({ ...filters, [k]: !filters[k] })
  if (!layout && !toggles.length && !scope && !shield && audience === null) return null
  const shieldName = shield && (shield.everyone ? "Everyone: unfiltered posts. Click for your Web of Trust"
    : shield.locked ? "Web of Trust. Everyone unlocks once you follow 5 people" : "Web of Trust: people you follow and the people they follow. Click for everyone")
  return (
    <div class="feed-toolbar" role="toolbar" aria-label="Feed options">
      {shield && <button type="button" class={`feed-tool on${shield.everyone ? " everyone" : ""}`} aria-pressed={shield.everyone} title={shieldName}
        aria-label={shield.everyone ? "Everyone" : "Web of Trust"} onClick={onShield}>
        <Icon d={shield.everyone ? SHIELD.everyone : shield.locked ? SHIELD.locked : SHIELD.trust} />
      </button>}
      {audience !== null && <select class="feed-tool feed-audience" aria-label="Popular from" title="Popular from" value={audience} onChange={e => onAudience(e.currentTarget.value)}>
        {AUDIENCES.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </select>}
      {ranks !== null && <button type="button" class={`feed-tool${ranks ? " on" : ""}`} aria-pressed={ranks} title="Ranks" aria-label="Ranks" onClick={onRanks}><Icon d={FLAME} /></button>}
      {(shield || audience !== null) && (scope || layout || toggles.length > 0) && <span class="feed-tool-divider" aria-hidden="true" />}
      {scope && ["following", "global"].map(s => (
        <button key={s} type="button" class={`feed-tool${scope === s ? " on" : ""}`} aria-pressed={scope === s}
          title={SCOPE_NAME[s]} aria-label={SCOPE_NAME[s]} onClick={() => onScope(s)}>
          <Icon d={SCOPE_ICON[s]} />
        </button>
      ))}
      {scope && (layout || toggles.length > 0) && <span class="feed-tool-divider" aria-hidden="true" />}
      {layout && <button type="button" class="feed-tool on" onClick={onCycleLayout}
        title={`${LAYOUT_NAME[layout]}. Switch to ${next}`} aria-label={`${LAYOUT_NAME[layout]}. Switch to ${next}`}>
        <Icon d={LAYOUT_ICON[layout]} />
      </button>}
      {layout && toggles.length > 0 && <span class="feed-tool-divider" aria-hidden="true" />}
      {toggles.map(k => (
        <button key={k} type="button" class={`feed-tool${filters[k] ? " on" : ""}`} aria-pressed={!!filters[k]}
          title={TOGGLE_NAME[k]} aria-label={TOGGLE_NAME[k]} onClick={() => flip(k)}>
          <Icon d={TOGGLE_ICON[k]} />
        </button>
      ))}
    </div>
  )
}
