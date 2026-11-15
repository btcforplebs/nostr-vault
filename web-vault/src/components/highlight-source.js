// A highlight's source, shared by the feed card (FeedKinds.jsx) and the Reader napplet's card (napplet/kind-cards.js).
/** A highlight's source (FeedHighlight): its `a` article, else its `e` note, else an http(s) `r` page. */
export function highlightSource(tags) {
  const a = tags.find(t => t[0] === "a" && t[1])?.[1]
  if (a) {
    const [kind, pubkey, ...d] = a.split(":")
    if (/^[0-9a-f]{64}$/.test(pubkey ?? "")) return { q: { type: "addr", kind: Number(kind), pubkey, d: d.join(":"), relays: [] } }
  }
  const e = tags.find(t => t[0] === "e" && /^[0-9a-f]{64}$/.test(t[1] ?? ""))?.[1]
  if (e) return { q: { type: "note", id: e, relays: [] } }
  const r = tags.find(t => t[0] === "r" && /^https?:\/\//.test(t[1] ?? ""))?.[1]
  return r ? { url: r } : null
}
