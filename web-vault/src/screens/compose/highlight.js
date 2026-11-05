// New Highlight (NIP-84, kind 9802; parity #28): the rules, as the iPhone's share-sheet highlight writes one
// (SharePortalKit HighlightPageLink.swift, HighlightShareTags.swift). No JSX, so tests can import it.

export const HIGHLIGHT_KIND = 9802
export const LINK_LABEL = "Page link (optional)"
export const LINK_PLACEHOLDER = "https://…"
export const LINK_HINT = "Paste the page's address to link the highlight to it."
export const LINK_PROBLEM = "That doesn't look like a web address."

/** HighlightPageLink.check: "" when nothing is typed, the web address (https:// added when left off), or null when
 *  it isn't one (Post waits until it is fixed or cleared). */
export function checkLink(typed) {
  const s = String(typed ?? "").trim()
  if (!s) return ""
  if (/\s/.test(s)) return null
  const lower = s.toLowerCase()
  let full
  if (lower.startsWith("https://") || lower.startsWith("http://")) full = s
  else if (lower.includes("://") || lower.startsWith("//")) return null
  else full = "https://" + s
  try {
    const u = new URL(full)
    if (!/^https?:$/.test(u.protocol)) return null
    const host = u.hostname
    if (!host.includes(".") || host.startsWith(".") || host.endsWith(".")) return null
    return full
  } catch { return null }
}

/** HighlightShareTags.tags: `r` names the page (marked source), `comment` makes it a quote highlight, `alt` says what
 *  it is. No `context`: only the words kept go out. */
export function highlightTags({ passage, link, comment }) {
  const out = []
  const p = String(passage ?? "").trim()
  const url = String(link ?? "").trim()
  if (/^https?:\/\//i.test(url)) out.push(["r", url, "source"])
  const c = String(comment ?? "").trim()
  if (c) out.push(["comment", c])
  out.push(["alt", `Highlight: "${p}"`])
  return out
}

export const emptyHighlight = () => ({ passage: "", link: "", comment: "" })
export const hasHighlight = d => !!(d.passage.trim() || d.link.trim() || d.comment.trim())
/** Ready to post: some words, and a link that is a web address or none. */
export const highlightComplete = d => !!d.passage.trim() && checkLink(d.link) !== null
