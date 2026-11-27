// The icon tab row over a profile's list (ProfileTabs.jsx), shared by your profile and someone else's.
if (import.meta.env) import("../styles/profile.css")

// Icons only, with the count beside them, as the iPhone's tabs (ProfileContent+Sections): its SF Symbols drawn as
// paths: text.bubble, photo.on.rectangle, arrowshape.turn.up.left, arrow.2.squarepath, at, doc.richtext, bag.
const TAB_ICONS = {
  notes: "M4 5h16v11H9l-4 3v-3H4zM8 9h8M8 12h5",
  media: "M7 7h13v11H7zM4 4h13M4 4v11M10 15l3-3 2 2 2-2 3 3M15.5 10.5h.01",
  replies: "M10 5L4 11l6 6M4 11h10a6 6 0 0 1 6 6v2",
  reposts: "M17 3l3 3-3 3M4 11V9a3 3 0 0 1 3-3h13M7 21l-3-3 3-3M20 13v2a3 3 0 0 1-3 3H4",
  tagged: "M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1",
  articles: "M6 3h9l4 4v14H6zM14 3v5h5M9 12h7M9 15h7M9 18h4",
  shop: "M5 8h14l-1 13H6zM9 8V6a3 3 0 0 1 6 0v2",
}
export const TabIcon = ({ id, size = 16 }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={TAB_ICONS[id]} /></svg>
)
// "48", or "48+" while older pages may still raise it: the notes loaded, not totals (the iPhone's countLabel).
const countLabel = (n, more) => (n > 0 ? (n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n)) + (more ? "+" : "") : "")

/** `tabs` from visibleTabs, `on` the open one, `count(id)` -> { n, more } for its count label. */
export function ProfileTabRow({ tabs, on, onPick, count }) {
  return (
    <div class="segmented profile-tabs" role="tablist" aria-label="Profile">
      {tabs.map(t => {
        const c = count(t.id), label = countLabel(c.n, c.more)
        return (
          <button key={t.id} role="tab" aria-selected={on === t.id} class={on === t.id ? "on" : ""} title={t.label}
            aria-label={label ? `${t.label}, ${label}` : t.label} onClick={() => onPick(t.id)}>
            <TabIcon id={t.id} />{label && <span class="tab-count">{label}</span>}
          </button>
        )
      })}
    </div>
  )
}
