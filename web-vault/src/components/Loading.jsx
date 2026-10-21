// Calm loading states for every screen that waits on a relay or a file: placeholder rows and tiles drawn in the real
// rows' own boxes (so nothing moves when the data lands), the splash, and a spinner for a button that is signing or
// publishing. The feed's note-shaped rows stay in FeedExtras.jsx (SkeletonRows). Styles: styles/loading.css, loaded
// with app.css so the first splash is never unstyled.

/** Placeholder list rows. `rowClass` is the real row's class (e.g. "dm-row"), so a placeholder takes its margins,
 *  padding and border; `avatar` is the real avatar's size (0 for none). `label` says what is loading, for screen
 *  readers (and the tests). */
export function SkeletonList({ count = 6, label = "Loading…", rowClass = "sk-row", avatar = 40, lines = 2 }) {
  return <div class="sk-list" aria-busy="true">
    <span class="sr-only">{label}</span>
    {Array.from({ length: count }, (_, i) => (
      <div class={`${rowClass} skeleton sk-item`} key={i} aria-hidden="true">
        {avatar > 0 && <span class="sk-avatar" style={{ width: avatar, height: avatar }} />}
        <span class="sk-lines">
          <span class="sk-bar" style={{ width: `${38 + (i * 17) % 30}%` }} />
          {lines > 1 && <span class="sk-bar sk-thin" style={{ width: `${62 + (i * 23) % 30}%` }} />}
        </span>
      </div>
    ))}
  </div>
}

/** Placeholder tiles inside the real grid's class (e.g. "vault-grid"), one `tileClass` box each. */
export function SkeletonGrid({ count = 12, label = "Loading media…", gridClass = "media-grid", tileClass = "sk-tile" }) {
  return <div class={gridClass} aria-busy="true">
    <span class="sr-only">{label}</span>
    {Array.from({ length: count }, (_, i) => <div class={`${tileClass} skeleton sk-tile`} key={i} aria-hidden="true" />)}
  </div>
}

/** A small round spinner. With `label` it is announced; without, it is decoration beside text that says it. */
export function Spinner({ label }) {
  return label ? <span class="nv-spin" role="status" aria-label={label} /> : <span class="nv-spin" aria-hidden="true" />
}

/** A line of muted text with a spinner, for a short wait inside a screen ("Loading replies…"). */
export function Waiting({ children }) {
  return <p class="waiting" role="status"><Spinner />{children}</p>
}

/** The app icon breathing over a status line: the same picture index.html draws before the code loads, so the hand-off
 *  from that first splash to this one doesn't jump. */
export function Splash({ children }) {
  return <main class="splash" aria-busy="true">
    <span class="splash-mark"><img src="./icon.svg" alt="" /></span>
    <p class="muted" role="status">{children}</p>
  </main>
}
