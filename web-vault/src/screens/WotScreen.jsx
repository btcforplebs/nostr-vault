// The Web of Trust tab, as the iPhone's (TrustWebView on the WOT tab): the globe fills the screen, you in the middle,
// your follows round you, then the people your follows vouch for, then further out (screens/WotGlobe.jsx). Over it,
// the layer pill and the tools capsule (WotTopBar.jsx), the trail of breadcrumbs, and the floating My Web button that
// opens the tab's dashboard (WotMyWeb.jsx). Tap someone for their trust card (WotCard.jsx).
// The address says what's up:
//   #/wot             you in the middle (the tab takes you back)
//   #/wot/<hex>       you in the middle with their card open and your paths to them lit: a profile's Web of Trust
//                     button, as the iPhone's "Open in WoT" (TrustWebView+Actions openRequested, Logen 10/23)
//   #/wot/<hex>/web   them in the middle, the people they follow round them: "See their web", one step further along
//                     the trail back to you. The layer and filter stay about you (Logen 10/15).
// Webs come from contact lists (net/wot.js); the globe's maths is net/wot-globe.js.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { followsOf } from "../net/follows.js"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPath, layerCounts, FURTHER_CAP, EXTENDED_CAP } from "../net/wot.js"
import { layout, layerFaceCandidates, pictured, LAYER_FACES, RING_FACES } from "../net/wot-globe.js"
import { WotGlobe } from "./WotGlobe.jsx"
import { TrustCard } from "./WotCard.jsx"
import { LayerMenu, WotToolbar, WotSearch } from "./WotTopBar.jsx"
import { WotMyWeb, WotGlobeIcon } from "./WotMyWeb.jsx"
import { fetchPersonLists } from "../net/person.js"

if (import.meta.env) import("../styles/wot.css")

const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
/** The address's "See their web" form, #/wot/<hex>/web. */
const theirWebHash = pk => `#/wot/${pk}/web`
const NOTE_MS = 2000

export function WotScreen({ ctx, pubkey }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  // You aren't one of your own follows, even when your list names you (TrustMap: myFollows minus you).
  const follows = useMemo(() => account.follows.filter(pk => pk !== me), [account.follows, me])
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null) // Map once the follows' lists are in
  const [status, setStatus] = useState("")
  const [layer, setLayer] = useState("everyone") // the layer menu (wot.js LAYERS)
  const [followsBackOn, setFollowsBackOn] = useState(false) // the Follow you back filter
  const [note, setNote] = useState("") // the filter's passing note
  const [picked, setPicked] = useState(null) // pubkey of the open trust card
  const [centre, setCentre] = useState(null) // pubkey to turn to the front of the globe
  const [missing, setMissing] = useState(0) // follows whose list didn't come back
  const [round, setRound] = useState(0) // Rebuild your web
  const [rebuilding, setRebuilding] = useState(false)
  const [searchOpen, setSearchOpen] = useState(false)
  const [myWebOpen, setMyWebOpen] = useState(false)
  const [crumbs, setCrumbs] = useState([me]) // the trail: you, then each person whose web you went on to
  const [frames, setFrames] = useState(() => new Map()) // someone on the trail -> { ring, listFound, lists }
  const stepping = useRef(null) // who See their web is moving onto, so the address change extends the trail
  const root = crumbs.at(-1)
  // Read on each render: the app re-renders this screen on every address change.
  const theirWeb = !!pubkey && pubkey !== me && location.hash.startsWith(theirWebHash(pubkey))

  useEffect(() => {
    if (!follows.length) { setStatus(""); return }
    if (!navigator.onLine) { setStatus("Your web needs the network: your follows' contact lists aren't kept in this browser."); return }
    let live = true
    setStatus("Mapping your web")
    if (round) setRebuilding(true)
    followLists(me, follows, round ? { retryMs: 0 } : {})
      .then(l => { if (live) { setLists(l); setMissing(missingLists(follows)); setStatus("") } })
      .finally(() => { if (live) setRebuilding(false) })
    fetchProfiles(vault, follows, uniq([...account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
    return () => { live = false }
  }, [me, follows.length, round])

  // Built once per set of lists; blocking or unblocking only filters it (buildWeb reads every list, filterWeb doesn't).
  // With no follows yet, an empty web: the globe still shows you (as on the iPhone), with a hint under the bar.
  const built = useMemo(() => (lists ? buildWeb(me, follows, lists) : !follows.length && account.loaded ? buildWeb(me, [], new Map()) : null), [lists, follows.length, account.loaded])
  const web = useMemo(() => (built ? filterWeb(built, lists ?? new Map(), blocked) : null), [built, blocked])

  // The address moved (see the top). Anything that isn't a step along the trail starts it again from you, with the
  // search, the card and My Web put away (openRequested).
  useEffect(() => {
    const from = stepping.current
    stepping.current = null
    if (theirWeb) {
      setCrumbs(c => { const i = c.indexOf(pubkey); return i >= 0 ? c.slice(0, i + 1) : from === pubkey ? [...c, pubkey] : [me, pubkey] })
      if (from !== pubkey) { setPicked(null); setSearchOpen(false); setMyWebOpen(false) }
      return
    }
    setCrumbs([me])
    setSearchOpen(false); setMyWebOpen(false)
    if (pubkey && pubkey !== me) { setPicked(pubkey); setCentre(pubkey) } else { setPicked(null); setCentre(me) }
  }, [pubkey, theirWeb, me])
  const goTo = pk => { location.hash = pk === me ? "#/wot" : theirWebHash(pk) }
  const seeTheirWeb = pk => { setPicked(null); stepping.current = pk; goTo(pk) }

  // Someone else in the middle: their follow list, then their follows' lists (kept only while they're on the trail).
  useEffect(() => {
    setFrames(f => { const keep = new Map([...f].filter(([pk]) => crumbs.includes(pk))); return keep.size === f.size ? f : keep })
  }, [crumbs.join()])
  useEffect(() => {
    if (root === me || frames.has(root)) return
    const update = v => setFrames(f => (f.has(root) ? new Map(f).set(root, { ...f.get(root), ...v }) : f))
    setFrames(f => new Map(f).set(root, { ring: null }))
    const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
    fetchProfiles(vault, [root], relays, { save: follows.includes(root) }).catch(() => {})
    fetchPersonLists(root, account.relays.read)
      .then(({ contacts }) => {
        const ring = followsOf(contacts)
        update({ ring, listFound: !!contacts, lists: ring.length ? null : new Map() })
        if (!ring.length) return
        fetchProfiles(vault, ring, relays, { save: false }).catch(() => {})
        return followLists(root, ring, { slot: "visit" }).then(l => update({ lists: l }))
      })
      .catch(() => update({ ring: [], listFound: false, lists: new Map() }))
  }, [root])
  const frame = root === me ? null : frames.get(root)
  const theirs = useMemo(() => (frame?.ring ? buildWeb(root, frame.ring, frame.lists ?? new Map(), { blocked }) : null), [frame, blocked])
  const globeWeb = root === me ? web : theirs
  const loadingRoot = root !== me && !(frame?.ring && frame.lists) // the trail's last chip spins
  const whose = root === me ? null : nameOf(root)

  // Who the globe leaves lit, about you on any globe (globeLit): Follow you back's people, and on someone else's
  // globe the layer's people too. null lights everyone.
  const lit = useMemo(() => {
    if (!web) return null
    const back = followsBackOn ? web.followsMe : null
    const mine = root !== me && layer !== "everyone" ? new Set(layer === "following" ? web.follows : layer === "close" ? web.extended : web.further) : null
    if (back && mine) return new Set([...back].filter(pk => mine.has(pk)))
    return back ?? mine
  }, [web, followsBackOn, layer, root])

  const globeLayer = root === me ? layer : "everyone"
  const shown = useMemo(() => (globeWeb ? { extended: shownByKey(globeWeb.extended, EXTENDED_CAP), further: shownByKey(globeWeb.further, FURTHER_CAP) } : null), [globeWeb])
  // Faces past the follows, by layer (TrustMap.faceCount): the candidates' profiles are fetched (strangers', so kept in
  // memory only), and the first with a picture, among the people the filter lights, become faces as they arrive.
  const candidates = useMemo(() => (globeWeb ? layerFaceCandidates(globeWeb, globeLayer).filter(pk => !lit || lit.has(pk)) : []), [globeWeb, globeLayer, lit])
  useEffect(() => { if (candidates.length) fetchProfiles(vault, candidates, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {}) }, [candidates])
  const [profilesIn, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  const faceKey = useMemo(() => pictured(candidates, pk => !!getProfile(pk)?.picture, LAYER_FACES[globeLayer]).join(), [candidates, profilesIn, globeLayer])
  // Your follows' faces: the most linked of them with a picture (on yours the iPhone picks those you interact with
  // most, which the browser doesn't know), up to RING_FACES; the rest stay stars.
  const ringKey = useMemo(() => {
    if (!globeWeb) return ""
    const n = pk => globeWeb.linkers.get(pk)?.length ?? 0
    const ring = [...globeWeb.follows].filter(pk => !lit || lit.has(pk)).sort((a, b) => n(b) - n(a))
    return pictured(ring, pk => !!getProfile(pk)?.picture, RING_FACES).join()
  }, [globeWeb, lit, profilesIn])
  const nodes = useMemo(() => (globeWeb ? layout({ ...globeWeb, extended: shown.extended }, shown.further, faceKey ? faceKey.split(",") : [], new Set(ringKey ? ringKey.split(",") : [])) : null), [globeWeb, shown, faceKey, ringKey])
  // Moving onto someone keeps the last globe up while theirs loads; only the very first globe has nothing to show.
  const last = useRef(null)
  if (globeWeb && nodes) last.current = { web: globeWeb, nodes, root }
  const showing = last.current
  // The open card's trust path, traced on your own globe.
  const path = useMemo(() => (picked && root === me ? trustPath(web, picked)?.all ?? [] : []), [picked, web, root])

  // A tap on a face turns the globe to it and opens its card; on you, on the open card's face or on nothing, it closes
  // the card (TrustWebView.tapped).
  const tapped = pk => {
    if (!pk || pk === me || pk === picked) { setPicked(null); return }
    setPicked(pk); setCentre(pk); setSearchOpen(false)
  }
  const counts = web ? layerCounts(web) : null
  const pickLayer = id => setLayer(id)
  const flipFollowsBack = () => {
    const on = !followsBackOn
    setFollowsBackOn(on)
    const n = web?.followsMe.size ?? 0
    setNote(!on ? "Follow you back off" : !web ? "Checking who follows you back…" : n === 0 ? "None of your follows follow you back" : n === 1 ? "1 follows you back" : `${n.toLocaleString()} follow you back`)
  }
  useEffect(() => { if (!note) return; const t = setTimeout(() => setNote(""), NOTE_MS); return () => clearTimeout(t) }, [note])

  // The pill under the bar while your web maps, and the one in the middle while there's nothing to draw yet.
  const live = root === me ? status : ""
  const middle = !account.loaded ? "Loading your follows…" : !showing && root !== me ? `Loading ${whose}'s follows…` : ""
  const hint = root === me && account.loaded && !follows.length ? "Follow someone to see your web: it's built from the people you follow and who they follow." : ""
  const noList = root !== me && frame?.ring && !frame.listFound ? `No relay had ${whose}'s follow list.` : ""

  return (
    <main class="screen wot">
      {showing && <WotGlobe key={showing.root} web={showing.web} nodes={showing.nodes} picked={picked} onPick={tapped} centre={centre} onCentred={() => setCentre(null)}
        layer={showing.root === me ? layer : "everyone"} lit={lit} path={path} whose={showing.root === me ? null : nameOf(showing.root)} />}
      <div class="wot-top">
        <div class="wot-bar">
          <LayerMenu layer={layer} counts={counts} onPick={pickLayer} onRebuild={() => setRound(r => r + 1)} rebuilding={rebuilding} missing={missing} />
          <WotToolbar searchOpen={searchOpen} onSearch={() => { setSearchOpen(!searchOpen); setPicked(null) }} followsBack={followsBackOn} onFollowsBack={flipFollowsBack} />
        </div>
        {searchOpen && <WotSearch web={web} me={me} onClose={() => setSearchOpen(false)} onPick={pk => { setSearchOpen(false); if (root !== me) goTo(me); setPicked(pk); setCentre(pk) }} />}
        {crumbs.length > 1 && (
          <nav class="wot-crumbs" aria-label="Whose web">
            {crumbs.map((pk, i) => [
              i > 0 && <span key={`${pk}>`} class="wot-crumb-sep" aria-hidden="true">›</span>,
              <button key={pk} type="button" class={i === crumbs.length - 1 ? "wot-crumb on" : "wot-crumb"} aria-current={i === crumbs.length - 1 ? "step" : undefined}
                title={i === crumbs.length - 1 ? undefined : "Goes back to this step"} onClick={() => goTo(pk)}>
                <Avatar pubkey={pk} size={22} />{pk === me ? "You" : nameOf(pk)}
                {i === crumbs.length - 1 && loadingRoot && <span class="wot-spin" role="status" aria-label={`Loading ${nameOf(pk)}'s follows`} />}
              </button>,
            ])}
          </nav>
        )}
        {live && <div class="wot-live" role="status"><span class="wot-spin" aria-hidden="true" />{live}</div>}
        {(note || hint || noList) && <div class="wot-note" role="status">{note || noList || hint}</div>}
      </div>
      {middle && <div class="wot-middle" role="status"><span class="wot-spin" aria-hidden="true" />{middle}</div>}
      {picked && web && <TrustCard ctx={ctx} web={web} built={built} root={root} pubkey={picked} onPick={pk => { setPicked(pk); setCentre(pk) }} onSeeWeb={seeTheirWeb} onClose={() => setPicked(null)} />}
      {!picked && !searchOpen && !myWebOpen && (
        <button type="button" class="wot-myweb-button" aria-label="My Web" title="Opens your web's dashboard" onClick={() => setMyWebOpen(true)}>
          <WotGlobeIcon />My Web
        </button>
      )}
      {myWebOpen && <WotMyWeb counts={counts} layer={layer} follows={follows.length} followsBack={lists ? web?.followsMe.size ?? 0 : null} followsBackOn={followsBackOn}
        missing={missing} rebuilding={rebuilding} onClose={() => setMyWebOpen(false)} onRebuild={() => setRound(r => r + 1)}
        onLayer={id => { setMyWebOpen(false); setLayer(id); if (root !== me) goTo(me) }}
        onFollowsBack={() => { setMyWebOpen(false); if (!followsBackOn) flipFollowsBack() }} />}
    </main>
  )
}
