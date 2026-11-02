// Web of Trust mini: a "Your space" panel. A small slow globe of your web (MiniGlobe.jsx), how many people are in it,
// and who is new in it: people your follows have come to vouch for since this browser last looked (wot-mini.js
// newInWeb). A click on a face opens their trust card in the left column (#/wot/<hex>); the globe opens the Web of Trust
// page. It reads the follows' lists the unread badge and Messages already load (wot.js followLists shares them), and
// publishes nothing.
import { useEffect, useMemo, useState } from "preact/hooks"
import { Avatar } from "../../components/Avatar.jsx"
import { AuthorName } from "../../components/NoteCard.jsx"
import { useBlocks } from "../../components/useBlocks.js"
import { WOT_GLOBE } from "../../components/wot-glyph.js"
import { followLists, missingLists, buildWeb, layerCounts } from "../../net/wot.js"
import { fetchProfiles } from "../../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../../net/pool.js"
import { MiniGlobe } from "./MiniGlobe.jsx"
import { newInWeb, readKept, writeKept, mapped, vouchText, globePoints, NEW_FACES } from "./wot-mini.js"
import { Icon } from "../Sidebar.jsx"
import "../../styles/wot-mini.css"

export function WotMini({ ctx }) {
  const me = ctx.session.pubkey
  const follows = useMemo(() => ctx.account.follows.filter(pk => pk !== me), [ctx.account.follows, me])
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows.at(-1) ?? ""}`
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null)
  const [missing, setMissing] = useState(0)
  useEffect(() => {
    if (!follows.length) return
    let live = true
    followLists(me, follows).then(l => { if (live) { setLists(l); setMissing(missingLists(follows)) } }).catch(() => {})
    return () => { live = false }
  }, [key])
  const web = useMemo(() => (lists ? buildWeb(me, follows, lists, { blocked }) : null), [lists, blocked])
  const ready = !!web && mapped(follows.length, missing)

  // Who is new, worked out once per web and kept for the next look.
  const fresh = useMemo(() => {
    if (!ready) return []
    const { fresh, kept } = newInWeb(web.extended, readKept(me), Math.floor(Date.now() / 1000))
    writeKept(me, kept)
    return fresh
  }, [web, ready])
  const faces = fresh.slice(0, NEW_FACES)
  useEffect(() => {
    if (!faces.length) return
    fetchProfiles(ctx.vault, faces, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { save: false }).catch(() => {})
  }, [faces.join()])
  const points = useMemo(() => (web ? globePoints(web, fresh) : []), [web, fresh])
  const counts = web ? layerCounts(web) : null

  const status = !ctx.account.loaded ? "Loading your follows…"
    : !follows.length ? "Follow someone to see your web: it's built from the people you follow and who they follow."
    : !web ? "Mapping your web…"
    : !ready ? "Part of your web is still missing. New people show here once it's all in."
    : null
  return (
    <section class="sp-panel wot-mini" aria-label="Web of Trust">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={WOT_GLOBE} size={15} /></span>
        <h3>Web of Trust</h3>
      </header>
      <div class="wm-top">
        <a class="wm-globe-link" href="#/wot" title="Open your web of trust"><MiniGlobe points={points} /></a>
        <dl class="wm-stats">
          <div><dt>in your web</dt><dd>{counts ? counts.everyone.toLocaleString() : "–"}</dd></div>
          <div><dt>you follow</dt><dd>{counts ? counts.following.toLocaleString() : "–"}</dd></div>
          <div><dt>vouched</dt><dd class="wm-vouched">{counts ? counts.close.toLocaleString() : "–"}</dd></div>
        </dl>
      </div>
      <div class="wm-new">
        <h4>New in your web{fresh.length > 0 && <span class="wm-count">{fresh.length}</span>}</h4>
        {status ? <p class="wm-note">{status}</p>
          : !faces.length ? <p class="wm-note">No one new yet. People show here when {web.extendedMin}+ of your follows start following them.</p>
          : (
            <ul class="wm-faces">
              {faces.map(pk => (
                <li key={pk}>
                  <a class="wm-face" href={`#/wot/${pk}`} title={vouchText(web, pk)}>
                    <Avatar pubkey={pk} size={36} />
                    <span class="wm-name"><AuthorName pubkey={pk} /></span>
                  </a>
                </li>
              ))}
            </ul>
          )}
      </div>
      <a class="sp-foot" href="#/wot">Open the globe ›</a>
    </section>
  )
}
