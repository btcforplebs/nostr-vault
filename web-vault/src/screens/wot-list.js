// The Web of Trust as a list (parity #7): the people the globe shows for the layer picked, in the globe's order
// (your follows, then the people your follows vouch for, then further out), each by how many of your follows follow
// them. No JSX, so tests can import it.

/** -> [{ pk, layer: "follow" | "extended" | "further", links }]: the layer's people (wot.js LAYERS ids), only those
 *  `lit` leaves lit when it is a Set (the Follow you back filter). */
export function listPeople(web, layer = "everyone", lit = null) {
  if (!web) return []
  const links = pk => web.linkers.get(pk)?.length ?? 0
  const byLinks = (a, b) => links(b) - links(a) || (a < b ? -1 : 1)
  const groups = layer === "following" ? [["follow", web.follows]] : layer === "close" ? [["extended", web.extended]]
    : layer === "furtherOut" ? [["further", web.further]] : [["follow", web.follows], ["extended", web.extended], ["further", web.further]]
  const out = []
  for (const [name, pks] of groups) for (const pk of [...pks].sort(byLinks)) if (!lit || lit.has(pk)) out.push({ pk, layer: name, links: links(pk) })
  return out
}

/** A row's second line: where they sit, and how many of your follows follow them. */
export function rowLine({ layer, links }) {
  const where = layer === "follow" ? "You follow them" : layer === "extended" ? "Vouched" : "Further out"
  return links ? `${where} · followed by ${links.toLocaleString()} you follow` : where
}

/** Rows drawn at a time; "Show more" adds the next lot. */
export const LIST_PAGE = 100
