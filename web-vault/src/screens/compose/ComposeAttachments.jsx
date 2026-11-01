// The composer's photo and video strip (ComposeView+Attachments): each tile with its upload state (a progress ring
// while it goes up, so you can keep typing), Retry when it didn't, ALT, and ✕, which also stops an upload under way.
// Moved out of ComposeScreen.jsx unchanged but for the ring.
import { isVideo } from "./media-kind.js"

/** A ring filling with `progress` (0..1); with none yet (waiting its turn, hashing, asking the signer) it spins. */
export function ProgressRing({ progress }) {
  const r = 15, c = 2 * Math.PI * r, known = typeof progress === "number"
  return (
    <svg class={known ? "compose-ring" : "compose-ring spinning"} viewBox="0 0 36 36" width="36" height="36" aria-hidden="true">
      <circle cx="18" cy="18" r={r} fill="none" stroke="rgb(255 255 255 / .25)" stroke-width="3.5" />
      <circle cx="18" cy="18" r={r} fill="none" stroke="#fff" stroke-width="3.5" stroke-linecap="round" transform="rotate(-90 18 18)"
        stroke-dasharray={c} stroke-dashoffset={known ? c * (1 - Math.max(0, Math.min(1, progress))) : c * 0.75} />
    </svg>
  )
}

/** `photos`: the draft's; `onAlt(id)`, `onRetry(id)`, `onRemove(id)`. */
export function ComposeAttachments({ photos, onAlt, onRetry, onRemove }) {
  if (!photos.length) return null
  return (
    <ul class="compose-photos" aria-label="Attachments">
      {photos.map((p, i) => {
        const kind = isVideo(p) ? "Video" : "Photo", described = !!p.alt?.trim(), going = p.status !== "done" && p.status !== "failed"
        const pct = typeof p.progress === "number" ? Math.round(p.progress * 100) : null
        return (
          <li key={p.id} class={`compose-photo ${p.status}`}>
            {kind === "Video"
              ? <video src={p.preview} muted playsinline preload="metadata" aria-label={described ? p.alt : `${kind} ${i + 1}`} />
              : <img src={p.preview} alt={described ? p.alt : `${kind} ${i + 1}`} />}
            {kind === "Video" && <span class="compose-photo-kind" aria-hidden="true">
              <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M8 5.5v13l11-6.5z" /></svg>
            </span>}
            {going && <span class="compose-photo-ring"><ProgressRing progress={p.progress} /></span>}
            {going && <span class="compose-photo-state" role="status" aria-label={pct == null ? "Uploading" : `Uploading, ${pct}%`}>{pct == null ? "Uploading…" : `${pct}%`}</span>}
            {p.status === "failed" && <span class="compose-photo-state" title={p.error}>Didn't upload</span>}
            {p.status === "failed" && p.file && <button type="button" class="compose-photo-retry" onClick={() => onRetry(p.id)}>Retry</button>}
            {/* Filled once described, hollow while not, so an undescribed one shows at a glance (ComposeView+Chrome altChip). */}
            {p.status !== "failed" && <button type="button" class={described ? "compose-alt described" : "compose-alt"}
              aria-label={described ? `Edit description of ${kind.toLowerCase()} ${i + 1}` : `Add description to ${kind.toLowerCase()} ${i + 1}`}
              title={described ? p.alt : "Describe this for screen readers"} onClick={() => onAlt(p.id)}>ALT</button>}
            <button type="button" class="compose-photo-remove" aria-label={going ? `Stop uploading and remove ${kind.toLowerCase()} ${i + 1}` : `Remove ${kind.toLowerCase()} ${i + 1}`} onClick={() => onRemove(p.id)}>
              <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
            </button>
          </li>
        )
      })}
    </ul>
  )
}
