// Settings › Media Servers › Suggested: known-good Blossom servers offered with an Add button. Checked live on
// 2026-10-28: each answers, keeps files, and the free ones take uploads from any npub. Left out on purpose:
// nostr.download and 24242.io delete files nobody opens, which is wrong for a vault. Prices and limits drift, so
// re-check before a release. Same list as iOS SuggestedMediaServers.swift and Android SuggestedMediaServers.kt.
export const SUGGESTED_MEDIA_SERVERS = [
  { url: "https://blossom.primal.net", note: "Free" },
  { url: "https://blossom.nostr.build", note: "Free up to 20 MB a file · paid plans from $18 a year" },
  { url: "https://nostr.media", note: "Free" },
  { url: "https://blossom.azzamo.media", note: "Free tier · paid from $3 a month" },
  { url: "https://blossom.jumble.social", note: "Free up to 20 MB a file" },
  { url: "https://nostrmedia.com", note: "Paid only · from $2.99 a month" },
]

export const suggestionHost = url => new URL(url).hostname

/** Where a listed server uploads: the apps send nostr.build's website addresses to blossom.nostr.build
 *  (HavenConfig.blossomUploadServer). */
function uploadHost(raw) {
  const s = String(raw ?? "").trim()
  let host
  try { host = new URL(/^[a-z]+:\/\//i.test(s) ? s : `https://${s}`).hostname.toLowerCase() } catch { return null }
  return (host === "nostr.build" || host.endsWith(".nostr.build")) ? "blossom.nostr.build" : host
}

/** The suggestions not already in `urls`, matched by where they upload. */
export function notYetAdded(urls, all = SUGGESTED_MEDIA_SERVERS) {
  const added = new Set(urls.map(uploadHost).filter(Boolean))
  return all.filter(s => !added.has(suggestionHost(s.url)))
}
