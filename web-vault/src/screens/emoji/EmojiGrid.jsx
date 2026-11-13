// One set's emoji as a grid of images, each with its :shortcode:. A dead link shows the copy found on another server
// (checked against its hash, net/emoji-links.js) or a dimmed tile with a red dot; a saved copy gets a mark.
export function EmojiGrid({ set, links = new Map(), saved = () => null, limit = Infinity }) {
  const shown = set.emoji.slice(0, limit)
  return (
    <div class="emoji-grid">
      {shown.map(e => {
        const state = links.get(e.url)
        const src = state?.moved ?? e.url
        const dead = state === "dead"
        const copy = saved(set, e)
        return (
          <figure key={e.code} class={`emoji-tile${dead ? " dead" : ""}`} title={`:${e.code}:${dead ? " (link is dead)" : state?.moved ? " (found on another server)" : ""}${copy ? " · saved in your vault" : ""}`}>
            {dead ? <span class="emoji-missing" aria-hidden="true">?</span> : <img src={src} alt={`:${e.code}:`} loading="lazy" decoding="async" referrerpolicy="no-referrer" />}
            <figcaption>{e.code}</figcaption>
            {dead && <span class="emoji-dot" aria-label="dead link" />}
            {copy && <span class="emoji-saved" aria-label="saved in your vault">✓</span>}
          </figure>
        )
      })}
      {set.emoji.length > shown.length && <span class="emoji-more">+{set.emoji.length - shown.length}</span>}
    </div>
  )
}
