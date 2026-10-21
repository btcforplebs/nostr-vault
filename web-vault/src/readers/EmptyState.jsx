// An empty feed, as the iPhone draws it: a bold title, a line saying why, and one button that does something about
// it (Show Global …, Try again).
export function EmptyState({ title, detail, action = null }) {
  return (
    <div class="empty reader-empty">
      <p><strong>{title}</strong></p>
      {detail && <p class="muted small">{detail}</p>}
      {action && <button type="button" class="link" onClick={action.onClick}>{action.label}</button>}
    </div>
  )
}
