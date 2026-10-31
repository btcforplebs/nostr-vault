// The iPhone's spam and noise check (FeedServiceTypes.swift FeedNote.isNoiseOrSpam), every branch, for what is shown
// under an article: comments (kind 1111 and kind 1 replies) and highlights, as ArticleReaderView drops them.

const graphemes = s => [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].map(g => g.segment)

const SPAM_KEYWORDS = [
  "relay status:", "relay uptime:", "ping time:", "block height:",
  "free bitcoin", "earn double bitcoin", "telegram channel for free",
  "pump telegram", "whatsapp group", "click here to claim",
]

/** Empty, a JSON or wallet-connect payload, 20 of one character in a row, a short post stuffed with hashtags (or with
 *  mentions when it isn't a reply), or a known bot or scam phrase. */
export function isNoiseOrSpam(content, tags = []) {
  const trimmed = String(content ?? "").trim() // Swift's whitespacesAndNewlines; String.trim covers the same set
  if (!trimmed) return true

  // 1. JSON / technical payloads (common in spam and telemetry).
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) return true
  const lower = trimmed.toLowerCase()
  if (lower.includes("nostr-wallet-connect") || lower.includes("\"method\":") || lower.includes("\"result\":") || lower.includes("nip47")) return true

  // 2. 20 or more of the same character in a row (spam lines, emoji floods). Characters as Swift counts them.
  const chars = graphemes(trimmed)
  let run = 1
  for (let i = 1; i < chars.length; i++) {
    run = chars[i] === chars[i - 1] ? run + 1 : 1
    if (run >= 20) return true
  }

  // 3. Hashtag or mention stuffing in a short post. A reply's p tags are every thread participant (NIP-10), so
  // mentions don't count against a reply.
  const list = Array.isArray(tags) ? tags : []
  const hashtags = list.filter(t => t.length >= 2 && t[0] === "t").length
  const isReply = list.some(t => t.length >= 2 && t[0] === "e" && (t.length < 4 || t[3] !== "mention"))
  const mentions = list.filter(t => t.length >= 2 && t[0] === "p").length
  if (chars.length < 100 && (hashtags > 6 || (!isReply && mentions > 6))) return true

  // 4. Bot status updates, advertising, phishing.
  return SPAM_KEYWORDS.some(k => lower.includes(k))
}
