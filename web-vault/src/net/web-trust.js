// Inside your web of trust, for what other people send you: thread replies, live chat, article comments and
// highlights, Tagged, zappers (Logen 2026-11-04: strangers' replies got past the web). The web is readers/trust.js
// globalTrust / net/popular.js trustSet (you, your follows and the people they follow), the set the Global feeds
// already use. While it loads it fails closed: only you, your follows and whoever the view names (`also`: the note's
// author, the stream's host) count as inside, so a stranger never shows and then goes.

/** Whether `pk` is inside the web. `trust`: the trust set, or null while it loads. */
export function insideWeb(pk, trust, { me = null, follows = [], also = [] } = {}) {
  if (!pk) return false
  if (pk === me || also.includes(pk)) return true
  return trust ? trust.has(pk) : follows.includes(pk)
}

/**
 * A thread's reply tree split by the web: `replies` keeps the inside replies (an outside reply's own inside replies
 * move up to its place, as visibleReplies does for blocked people), `outside` lists the outside ones, oldest first, to
 * be folded under "Outside your web". `keep(event)`: always inside (the focused note, so a stranger's reply opened
 * from a link still shows). -> { replies, outside: [event] }
 */
export function splitOutside(replies, inside, keep = () => false) {
  const outside = []
  const walk = nodes => nodes.flatMap(n => {
    const children = walk(n.children ?? [])
    if (inside(n.event.pubkey) || keep(n.event)) return [{ event: n.event, children }]
    outside.push(n.event)
    return children
  })
  const kept = walk(replies)
  outside.sort((a, b) => a.created_at - b.created_at || (a.id < b.id ? -1 : 1))
  return { replies: kept, outside }
}
