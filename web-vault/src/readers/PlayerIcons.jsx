// Line icons for the player, in the text colour (emoji draw as coloured tiles).
export const Glyph = ({ d, one = false, size = 20 }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={d} />{one && <text x="12" y="15.5" font-size="10" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none">1</text>}
  </svg>
)
export const QUEUE = "M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"
export const SHUFFLE = "M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5"
export const REPEAT = "M17 1l4 4-4 4M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 0 1-4 4H3"
export const DOWN = "M6 9l6 6 6-6"
export const REPEAT_LABEL = { off: "Repeat off", all: "Repeat all", one: "Repeat one" }
