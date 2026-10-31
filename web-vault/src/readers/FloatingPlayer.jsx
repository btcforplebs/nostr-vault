// The app-wide player bar (the iPhone's FloatingButtonRow mini player): while a song or a minimized stream plays and
// the screen has no player bar of its own, a compact bar floats above the tab bar, beside Post. Tapping it opens
// Now Playing; play/pause and ✕ work from anywhere. Artist, album and "Back to the stream" stay on Music and Live.
import { PlayerBar } from "./PlayerBar.jsx"

if (import.meta.env) import("./readers.css")

export function FloatingPlayer() {
  return <PlayerBar floating />
}
