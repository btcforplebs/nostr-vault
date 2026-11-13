// Global's banner while the Everyone shield is on (net/global-trust.js EVERYONE_BANNER): what it means, and one tap
// back to the web of trust. Drawn by FeedScreen above the notes on any Global view (Global, Media on Global).
import { EVERYONE_BANNER } from "../net/global-trust.js"
if (import.meta.env) import("../styles/everyone-banner.css")

export function EveryoneBanner({ onBack }) {
  return (
    <div class="everyone-banner" role="status">
      <span>{EVERYONE_BANNER.text}</span>
      <button type="button" class="small" onClick={onBack}>{EVERYONE_BANNER.back}</button>
    </div>
  )
}
