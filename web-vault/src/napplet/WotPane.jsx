// The WoT tab as the WoT napplet (plan P6), when the napplet switch is on (flag.js). Logen's decision 6: the web of
// trust stays in the shell. This pane builds it exactly as the classic tab does (WotScreen.jsx: follow lists, blocks,
// the drawn caps, the face candidates' profiles) and hands the napplet a drawing-ready scene by intent
// (napplet:wot/show); the napplet only draws it. It asks back for napplet:profile/open and napplet:wot/refresh.
// `open`: a pubkey whose card opens first (#/wot/<hex>). "See their web" (#/wot/<hex>/web) stays the classic screen.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, FURTHER_CAP, EXTENDED_CAP } from "../net/wot.js"
import { layerFaceCandidates } from "../net/wot-globe.js"
import { sceneOf, waitingScene } from "./wot-scene.js"
import { WOT_DTAG } from "./first-party.js"
import { usePaneNapplet } from "./usePaneNapplet.js"
import "./napplet.css"

const HEX = /^[0-9a-f]{64}$/
const SEND_EVERY_MS = 600

export function WotPane({ ctx, open = null }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const follows = useMemo(() => account.follows.filter(pk => pk !== me), [account.follows, me])
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null)
  const [status, setStatus] = useState("")
  const [round, setRound] = useState(0)
  const [profilesIn, bump] = useState(0)
  const host = useRef(null)

  // The web, as the classic tab builds it.
  useEffect(() => {
    if (!follows.length) { setStatus(""); return }
    if (!navigator.onLine) { setStatus("Your web needs the network: your follows' contact lists aren't kept in this browser."); return }
    let on = true
    setStatus("Mapping your web")
    followLists(me, follows, round ? { retryMs: 0 } : {})
      .then(l => { if (on) { setLists(l); const m = missingLists(follows); setStatus(m ? `${m} of your follows' lists didn't come back` : "") } })
    fetchProfiles(vault, follows, uniq([...account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
    return () => { on = false }
  }, [me, follows.length, round])
  const built = useMemo(() => (lists ? buildWeb(me, follows, lists) : !follows.length && account.loaded ? buildWeb(me, [], new Map()) : null), [lists, follows.length, account.loaded])
  const web = useMemo(() => (built ? filterWeb(built, lists ?? new Map(), blocked) : null), [built, blocked])
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  // Strangers' profiles for the faces past your follows: fetched, kept in memory only, as the classic tab does.
  useEffect(() => {
    if (!web) return
    const drawnWeb = { ...web, extended: shownByKey(web.extended, EXTENDED_CAP), further: shownByKey(web.further, FURTHER_CAP) }
    const c = uniq(["everyone", "close", "furtherOut"].flatMap(l => layerFaceCandidates(drawnWeb, l)))
    if (c.length) fetchProfiles(vault, c, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {})
  }, [web])

  // The napplet: mounted once; the shell answers Open profile and Look again itself.
  const { live, note, ready } = usePaneNapplet(ctx, host, {
    dTag: WOT_DTAG, actions: { wot: ["show"] },
    handlers: [
      { id: "shell-profile", title: "Profile", archetype: "profile", actions: ["open"], conventions: [], deliver: p => { if (!HEX.test(p?.pubkey ?? "")) return { ok: false, error: "not a pubkey" }; location.hash = `#/profile/${p.pubkey}`; return { ok: true } } },
      { id: "shell-wot", title: "Web of Trust", archetype: "wot", actions: ["refresh"], conventions: [], deliver: () => { setRound(r => r + 1); return { ok: true } } },
    ],
  })

  // Send the scene when the web, the profiles or the address change, at most every SEND_EVERY_MS.
  const sentAt = useRef(0), pending = useRef(null), opened = useRef(null)
  useEffect(() => {
    const l = live.current
    if (!l) return
    const send = () => {
      pending.current = null; sentAt.current = Date.now()
      const first = open && opened.current !== open ? open : null
      opened.current = open
      l.invoke({ archetype: "wot", action: "show", payload: web ? sceneOf(web, { profile: getProfile, status, open: first }) : waitingScene(me, status || "Loading your follows…") })
    }
    clearTimeout(pending.current)
    const wait = SEND_EVERY_MS - (Date.now() - sentAt.current)
    if (wait <= 0 || open !== opened.current) send(); else pending.current = setTimeout(send, wait)
    return () => clearTimeout(pending.current)
  }, [web, profilesIn, status, open, ready])

  return (
    <main class="screen wot-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host wot-host" ref={host} />
    </main>
  )
}
