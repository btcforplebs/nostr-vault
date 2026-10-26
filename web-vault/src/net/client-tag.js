// The client tag Nostr Vault adds to what it posts, as the iPhone (EventPublisher.appendClientTag) and Android
// (EventPublisher.kt) add it: kind 1 notes and NIP-22 comments only, never twice, and no setting turns it off.
// The value names the platform the same way theirs do ("Nostr Vault on iOS", "… on Android").
import { COMMENT_KIND } from "./feed-kinds.js"

export const CLIENT_NAME = "Nostr Vault on Web"

/** `tags` with ["client", CLIENT_NAME] added for a kind 1 or 1111 that has no client tag yet; otherwise `tags` as is. */
export function appendClientTag(tags, kind) {
  if (kind !== 1 && kind !== COMMENT_KIND) return tags
  if (tags.some(t => t[0] === "client")) return tags
  return [...tags, ["client", CLIENT_NAME]]
}
