// Global's Everyone shield, the two questions before it opens (iPhone FeedView+TrustScope.swift; parity #20): the
// sensitive-content warning, or while you follow too few people, why it is locked (global-trust.js).
import { Dialog } from "./Moderation.jsx"
import { EVERYONE_WARNING, unlockText } from "../net/global-trust.js"

export function EveryoneShieldDialog({ ask, follows, me, onProceed, onClose }) {
  if (ask === "lock") return (
    <Dialog label="Everyone is locked" onClose={onClose}>
      <h3>Everyone is locked</h3>
      <p class="muted small">{unlockText(follows, me)}. Until then Global shows your Web of Trust: people you follow and the people they follow.</p>
      <div class="mod-row"><button type="button" class="primary" onClick={onClose}>OK</button></div>
    </Dialog>
  )
  return (
    <Dialog label={EVERYONE_WARNING.title} onClose={onClose}>
      <h3>{EVERYONE_WARNING.title}</h3>
      <p class="muted small">{EVERYONE_WARNING.text}</p>
      <div class="mod-row">
        <button type="button" class="danger" onClick={onProceed}>{EVERYONE_WARNING.proceed}</button>
        <button type="button" onClick={onClose}>{EVERYONE_WARNING.cancel}</button>
      </div>
    </Dialog>
  )
}
