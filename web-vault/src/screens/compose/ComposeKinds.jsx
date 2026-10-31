// What New Post writes: a note, an article or a poll. The iPhone picks the composer from the feed you're on
// (Views/FeedActions.swift); the web has one Post button, so the choice sits at the top of the sheet instead.
// Each kind keeps its own draft, so switching never loses what's written.
// Vite only: the node tests load this file without a CSS loader.
if (import.meta.env) import("../../styles/compose-kinds.css")

export const COMPOSE_TYPES = [["note", "Note"], ["article", "Article"], ["poll", "Poll"]]

const TYPES = new Set(COMPOSE_TYPES.map(([t]) => t))

/** "#/compose?type=article" -> "article"; anything else (a bare #/compose, a reply, a quote) is a note. */
export function composeType(hash = globalThis.location?.hash ?? "") {
  const m = /^#\/?compose\?type=([a-z]+)$/.exec(hash)
  return m && TYPES.has(m[1]) ? m[1] : "note"
}
export const composeHref = type => (type === "note" ? "#/compose" : `#/compose?type=${type}`)

/** Replaces the address, so Back still closes Compose instead of stepping through the kinds. */
export function ComposeKinds({ type }) {
  return (
    <nav class="segmented compose-kinds" aria-label="What to post">
      {COMPOSE_TYPES.map(([t, label]) => (
        <button key={t} type="button" class={t === type ? "on" : ""} aria-current={t === type ? "page" : undefined}
          onClick={() => { if (t !== type) location.replace(composeHref(t)) }}>{label}</button>
      ))}
    </nav>
  )
}
