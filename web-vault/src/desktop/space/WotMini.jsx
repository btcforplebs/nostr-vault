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
import { followLists, missingLists, unsettledLists, onListsProgress, buildWeb, layerCounts, RETRY_MS } from "../../net/wot.js"
import { fetchProfiles } from "../../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../../net/pool.js"
import { MiniGlobe } from "./MiniGlobe.jsx"
import { newInWeb, readKept, writeKept, mapped, loadingText, vouchText, globePoints, NEW_FACES, MAP_ROUNDS } from "./wot-mini.js"
import { Icon } from "../Sidebar.jsx"
import "../../styles/wot-mini.css"

export function WotMini({ ctx, open = true, tools = null }) {
  const me = ctx.session.pubkey
  const follows = useMemo(() => ctx.account.follows.filter(pk => pk !== me), [ctx.account.follows, me])
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows.at(-1) ?? ""}`
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null)
  const [unsettled, setUnsettled] = useState(0) // lists cut off, not known to be missing (wot.js unsettledLists)
  const [have, setHave] = useState(0) // follows' lists in so far, for the loading line
  const [gaveUp, setGaveUp] = useState(false)
  useEffect(() => {
    if (!follows.length) return
    let live = true, round = 0, timer
    // How far the lists have got, as each group lands (wot.js onListsProgress): a scan of every follow on each group,
    // not every second.
    const read = () => { if (!live) return; setHave(follows.length - missingLists(follows)); setUnsettled(unsettledLists(follows)) }
    const off = onListsProgress(() => read())
    // Lists cut off are asked for again, RETRY_MS apart, a few times: a web built from part of them would call people
    // "new" later who only came back with their bridge's list.
    const go = () => followLists(me, follows).then(l => {
      if (!live) return
      const left = unsettledLists(follows)
      setLists(l); setUnsettled(left); setHave(l.size)
      if (mapped(follows.length, left)) off()
      else if (++round < MAP_ROUNDS) timer = setTimeout(go, RETRY_MS + 1000)
      else { off(); setGaveUp(true) }
    }).catch(() => {})
    go()
    return () => { live = false; off(); clearTimeout(timer) }
  }, [key])
  const web = useMemo(() => (lists ? buildWeb(me, follows, lists, { blocked }) : null), [lists, blocked])
  const ready = !!web && mapped(follows.length, unsettled)

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
    : gaveUp && !ready ? `${unsettled.toLocaleString()} of your follows' lists didn't arrive. New people show here once they do.`
    : !ready ? `${loadingText(have, follows.length)}…`
    : null
  return (
    <section class={open ? "sp-panel wot-mini" : "sp-panel wot-mini closed"} aria-label="Web of Trust">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={WOT_GLOBE} size={15} /></span>
        <h3>Web of Trust</h3>
        {!open && fresh.length > 0 && <span class="sp-count" role="img" aria-label={`${fresh.length} new in your web`}>{fresh.length}</span>}
        {tools}
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
