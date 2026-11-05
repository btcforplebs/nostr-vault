// Settings › Media & Cache (iPhone MediaSettingsView): Playback's Autoplay Videos. The phone also keeps its own copies
// of media (Disable Media Cache, Keep Media For, Clear Media Cache); this page keeps none, the browser caches media
// itself, so the Cache section says where to clear it instead of offering switches that would do nothing.
import { AutoplaySwitch } from "../../components/AutoplaySwitch.jsx"
import { Section } from "./Section.jsx"

export const CACHE_NOTE = "This page keeps no copies of images and videos: your browser caches them. To clear them, clear this site's data in your browser's settings. Your vault and your media servers are not touched."

export function MediaCachePage() {
  return (
    <>
      <Section label="Playback"><AutoplaySwitch /></Section>
      <Section label="Cache"><p class="settings-note muted small">{CACHE_NOTE}</p></Section>
    </>
  )
}
