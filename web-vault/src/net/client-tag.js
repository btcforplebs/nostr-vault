// The client tag Nostr Vault adds to what it posts, as the iPhone (EventPublisher.appendClientTag) and Android
// (EventPublisher.kt) add it: kind 1 notes and NIP-22 comments only, never twice, and no setting turns it off.
// The value names the platform the same way theirs do ("Nostr Vault on iOS", "… on Android").
import { COMMENT_KIND } from "./feed-kinds.js"

export const CLIENT_NAME = "Nostr Vault on Web"
export const LINUX_CLIENT_NAME = "Nostr Vault on Linux"
// The Linux desktop window (linux/native/desktop/nostr-vault-desktop) adds this to WebKit's user agent: the same web
// app, shown in that window, posts as "on Linux". A plain browser on Linux has no such word and stays "on Web".
export const LINUX_UA_MARK = "NostrVaultLinux"

/** The client name for the page's own user agent (read at each post, not once at load). */
export function clientName(ua = globalThis.navigator?.userAgent ?? "") {
  return new RegExp(`(^|\\s)${LINUX_UA_MARK}/`).test(String(ua)) ? LINUX_CLIENT_NAME : CLIENT_NAME
}

/** `tags` with ["client", <name>] added for a kind 1 or 1111 that has no client tag yet; otherwise `tags` as is. */
export function appendClientTag(tags, kind, name = clientName()) {
  if (kind !== 1 && kind !== COMMENT_KIND) return tags
  if (tags.some(t => t[0] === "client")) return tags
  return [...tags, ["client", name]]
}
