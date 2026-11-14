// The WoT napplet's scene (plan P6): what the shell hands the napplet to draw, from the web the shell built. Pure (no
// DOM, no network), so node tests compare the napplet's globe with the classic tab's.
import { shownByKey, layerCounts, FURTHER_CAP, EXTENDED_CAP } from "../net/wot.js"
import { layerFaceCandidates } from "../net/wot-globe.js"

const HEX = /^[0-9a-f]{64}$/

/**
 * The scene the napplet draws, from the web the shell built (pure, for tests): the drawn people (shownByKey caps),
 * who links whom as indices into `follows`, who follows you back, names and pictures (follows and face candidates),
 * the full layer counts, a status line, and whose card to open.
 */
export function sceneOf(web, { profile = () => null, status = "", open = null } = {}) {
  const extended = shownByKey(web.extended, EXTENDED_CAP), further = shownByKey(web.further, FURTHER_CAP)
  const index = new Map(web.follows.map((pk, i) => [pk, i]))
  const linkers = {}
  for (const pk of [...web.follows, ...extended, ...further]) {
    const by = web.linkers.get(pk)
    if (by?.length) linkers[pk] = by.map(f => index.get(f)).filter(i => i !== undefined)
  }
  const drawnWeb = { ...web, extended, further }
  const wanted = new Set([...web.follows, ...["everyone", "close", "furtherOut"].flatMap(l => layerFaceCandidates(drawnWeb, l))])
  if (open) wanted.add(open)
  const profiles = {}
  for (const pk of wanted) { const p = profile(pk); if (p && (p.name || p.picture)) profiles[pk] = [String(p.name ?? "").slice(0, 80), /^https:\/\//i.test(p.picture ?? "") ? p.picture : ""] }
  return { me: web.me, follows: [...web.follows], extended, further, linkers, followsMe: [...web.followsMe], profiles, counts: layerCounts(web), status, open: HEX.test(open ?? "") ? open : null }
}


/** Before the web is built: just you, and what the shell is doing ("Mapping your web"). */
export const waitingScene = (me, status) => ({ me, follows: [], extended: [], further: [], linkers: {}, followsMe: [], profiles: {}, counts: null, status, open: null, waiting: true })
