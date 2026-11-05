// Where a setting's (i) bubble goes (components/SettingInfo.jsx). No JSX, so tests can import it.

/** For a button at `r` in a window `w` wide: under it, 280 wide, kept 8px inside the window. */
export const popAt = (r, w, width = 280) => ({ top: Math.round(r.bottom + 6), left: Math.round(Math.max(8, Math.min(r.left - 12, w - width - 8))), width })
