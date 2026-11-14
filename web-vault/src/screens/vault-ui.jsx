// The Vault tab's glyphs and its pill menus, shared by the Vault tab (VaultScreen.jsx) and the pages its menu opens.
import { useEffect, useRef, useState } from "preact/hooks"

export const ICONS = {
  bookmarks: "M6 3h12v18l-6-4-6 4z",
  apps: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
  emoji: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8.5 14.5a4.5 4.5 0 0 0 7 0M9 9.5h.01M15 9.5h.01",
  bell: "M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15zM10 20a2 2 0 0 0 4 0",
  activity: "M3 13h5l1.5 3h5L16 13h5M3 13l2-7h14l2 7v6H3z",
  notes: "M6 3h9l5 5v13H6zM14 3v6h6M9 13h6M9 17h6",
  articles: "M6 3h9l5 5v13H6zM14 3v6h6M9 12h3M9 16h6M14 12h1",
  highlights: "M4 20h7M14 3l7 7-9 9H7l-1-1zM9 14l5-5",
  media: "M3 6h14v12H3zM7 21h14V9M3 15l4-4 4 4 3-3 3 3",
  likes: "M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.5A4 4 0 0 1 19 10c0 5.5-7 10-7 10z",
  zaps: "M13 2L4 14h7l-1 8 9-12h-7z",
  followers: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8",
  dashboard: "M4 4h16v16H4zM4 10h16M10 10v10",
  filter: "M4 6h16M7 12h10M10 18h4",
  envelope: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM3 7l9 6 9-6",
  refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
  search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM21 21l-5-5",
  // The phone's filter glyphs (VaultToolbar trailingFilters), by filter id.
  stack: "M7 3h10M5 7h14M4 11h16v10H4z",
  at: "M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1",
  person: "M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
  fork: "M7 3v8M5 3v5a2 2 0 0 0 4 0V3M7 11v10M17 3c-2 0-3 3-3 6s1 4 3 4v8",
  trayIn: "M3 14h5l1.5 3h5L16 14h5v6H3zM12 3v9M8.5 8.5L12 12l3.5-3.5",
  trayOut: "M3 14h5l1.5 3h5L16 14h5v6H3zM12 12V3M8.5 6.5L12 3l3.5 3.5",
  sparkles: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z",
  photo: "M4 5h16v14H4zM4 16l5-5 4 4 2-2 5 5M15.5 9.5h.01",
  video: "M4 6h12v12H4zM16 10l5-3v10l-5-3",
  gif: "M4 5h16v14H4zM10 10H8v4h2v-1.5M13 10v4M16.5 14v-4H18M16.5 12H18",
  // Media's type menu (square.grid.2x2) and a page's ··· menu.
  grid: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
  more: "M5 12h.01M12 12h.01M19 12h.01",
  outside: "M10 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21a8 8 0 0 1 12.5-6.6M18 15a2 2 0 1 1 2 2v1.5M20 21h.01",
}
export const FILTER_ICONS = { all: "stack", mentions: "at", tagged: "at", mine: "person", recipes: "fork", received: "trayIn", given: "trayOut", new: "sparkles", photos: "photo", videos: "video", gifs: "gif", notes: "notes", outside: "outside" }
export const filterIcon = (mode, id) => ICONS[mode === "followers" && id === "all" ? "followers" : FILTER_ICONS[id]]
export const Icon = ({ d, size = 16, width = 1.8 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width={width} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

export const Chevron = () => <svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>

/** A pill that opens a list under it, closed by a pick, a tap outside or Escape. */
/** `pill`: the opener's class (a capsule icon button instead of the labelled pill). */
export function Menu({ label, title, align = "left", pill = "vault-pill", children }) {
  const [open, setOpen] = useState(false)
  const ref = useRef()
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  return (
    <div class={`vault-menu ${align}`} ref={ref} onClick={e => { if (e.target.closest("[role=menuitem]")) setOpen(false) }}>
      <button class={`${pill} ${open ? "open" : ""}`} aria-haspopup="menu" aria-expanded={open} aria-label={title} onClick={() => setOpen(!open)}>{label}</button>
      {open && <div class="vault-menu-list" role="menu">{children}</div>}
    </div>
  )
}
export const MenuItem = ({ on, onClick, children }) => <button role="menuitem" class={on ? "on" : ""} aria-checked={on} onClick={onClick}>{children}</button>
