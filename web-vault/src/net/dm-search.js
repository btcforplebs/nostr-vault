// Messages search (Logen, 2026-11-03): names and message text, searched on this device only, over the messages the
// page has already opened. The query never leaves the page: nothing here asks a relay, a search server or the signer.

/** Lower case, accents and extra spaces folded, so "Zoë" finds "zoe" and "  meet  up" finds "meet up". */
export const fold = (s = "") => String(s).normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/\s+/g, " ").trim()

/**
 * The conversations of `list` (newest first, as the screen draws them) that match `query`, in the same order ->
 * [{ ...conversation, hit }]. A conversation matches on its person's name (`nameOf(peer)`, from profiles already
 * loaded) or on any message in it; `hit` is the newest message whose text matches, to show instead of the last line,
 * or null when only the name matched. An empty query gives `list` back as it is.
 */
export function searchChats(list, messages, query, nameOf = () => "") {
  const q = fold(query)
  if (!q) return list
  const byPeer = new Map()
  for (const m of messages.values()) {
    if (!fold(m.content).includes(q)) continue
    const best = byPeer.get(m.peer)
    if (!best || m.at > best.at) byPeer.set(m.peer, m)
  }
  const out = []
  for (const c of list) {
    const hit = byPeer.get(c.peer) ?? null
    if (hit || fold(nameOf(c.peer)).includes(q)) out.push({ ...c, hit })
  }
  return out
}
