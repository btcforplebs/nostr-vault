const TABS = [
  ["feed", "Following", "M4 6h16M4 12h16M4 18h10"],
  ["compose", "Post", "M12 5v14M5 12h14"],
  ["profile", "Profile", "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0"],
  ["relay", "Relay", "M5 12a7 7 0 0 1 14 0M8.5 12a3.5 3.5 0 0 1 7 0M12 12v8"],
]

export function TabBar({ route }) {
  return (
    <nav class="tabbar">
      {TABS.map(([id, label, d]) => (
        <a key={id} href={`#/${id}`} class={route === id ? "tab on" : "tab"} aria-label={label}>
          <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d={d} /></svg>
          <span>{label}</span>
        </a>
      ))}
    </nav>
  )
}
