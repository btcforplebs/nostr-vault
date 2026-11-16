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
import { followsOf, setFollow } from "../net/follows.js"
import { fetchPersonLists } from "../net/person.js"
import { npubEncode } from "nostr-tools/nip19"
import { layerFaceCandidates } from "../net/wot-globe.js"
import { sceneOf, waitingScene } from "./wot-scene.js"
import { WOT_DTAG } from "./first-party.js"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { holdDark } from "../net/appearance.js"
import "./napplet.css"

const HEX = /^[0-9a-f]{64}$/
const SEND_EVERY_MS = 600

export function WotPane({ ctx, open = null, root = null }) {
  useEffect(() => holdDark(), []) // the Web of Trust is always Dark, and so is the page around it while it shows
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

  // See their web (#/wot/<hex>/web): their follow list, then their follows' lists, as the classic tab builds it
  // (WotScreen.jsx), kept only while they're in the middle.
  const theirRoot = HEX.test(root ?? "") && root !== me ? root : null
  const [frame, setFrame] = useState(null) // { root, ring, lists }
  useEffect(() => {
    setFrame(null)
    if (!theirRoot) return
    let on = true
    const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
    fetchProfiles(vault, [theirRoot], relays, { save: follows.includes(theirRoot) }).catch(() => {})
    setFrame({ root: theirRoot, ring: null })
    fetchPersonLists(theirRoot, account.relays.read)
      .then(({ contacts }) => {
        const ring = followsOf(contacts)
        if (!on) return
        setFrame({ root: theirRoot, ring, lists: ring.length ? null : new Map() })
        if (!ring.length) return
        fetchProfiles(vault, ring, relays, { save: false }).catch(() => {})
        return followLists(theirRoot, ring, { slot: "visit" }).then(l => { if (on) setFrame({ root: theirRoot, ring, lists: l }) })
      })
      .catch(() => { if (on) setFrame({ root: theirRoot, ring: [], lists: new Map() }) })
    return () => { on = false }
  }, [theirRoot])
  const theirs = useMemo(() => (frame?.ring && frame.lists ? buildWeb(frame.root, frame.ring, frame.lists, { blocked }) : null), [frame, blocked])
  useEffect(() => {
    if (!theirs) return
    const c = uniq(["everyone", "close", "furtherOut"].flatMap(l => layerFaceCandidates({ ...theirs, extended: shownByKey(theirs.extended, EXTENDED_CAP), further: shownByKey(theirs.further, FURTHER_CAP) }, l)))
    if (c.length) fetchProfiles(vault, c, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {})
  }, [theirs])
  const ctxRef = useRef(ctx)
  ctxRef.current = ctx

  // The napplet: mounted once; the shell answers Open profile and Look again itself.
  const { live, note, ready } = usePaneNapplet(ctx, host, {
    dTag: WOT_DTAG, actions: { wot: ["show"] },
    handlers: [
      { id: "shell-profile", title: "Profile", archetype: "profile", actions: ["open"], conventions: [], deliver: p => { if (!HEX.test(p?.pubkey ?? "")) return { ok: false, error: "not a pubkey" }; location.hash = `#/profile/${p.pubkey}`; return { ok: true } } },
      { id: "shell-wot", title: "Web of Trust", archetype: "wot", actions: ["refresh"], conventions: [], deliver: () => { setRound(r => r + 1); return { ok: true } } },
      // See their web, and back to you: an address, so Back steps along the trail as on the classic tab.
      { id: "shell-wot-web", title: "Their web", archetype: "wot", actions: ["web"], conventions: [], deliver: p => {
        if (!HEX.test(p?.pubkey ?? "")) return { ok: false, error: "not a pubkey" }
        location.hash = p.pubkey === ctxRef.current.session.pubkey ? "#/wot" : `#/wot/${p.pubkey}/web`
        return { ok: true }
      } },
      // Follow / Unfollow: kind 3 is never signed for a napplet (policy.js ACCOUNT_KINDS); the shell runs the classic
      // card's own setFollow, with all its list safety (net/follows.js), and reloads the account.
      { id: "shell-wot-follow", title: "Follow", archetype: "wot", actions: ["follow"], conventions: [], deliver: async p => {
        const c = ctxRef.current, { vault: v, signer, session, account } = c
        if (!HEX.test(p?.pubkey ?? "") || p.pubkey === session.pubkey || typeof p.follow !== "boolean") return { ok: false, error: "invalid request" }
        if (signer?.readOnly) return { ok: false, error: "This sign-in can't change your follows." }
        if (account.follows.includes(p.pubkey) === p.follow) return { ok: true }
        try {
          await setFollow({ vault: v, signer, pubkey: session.pubkey, target: p.pubkey, follow: p.follow,
            readRelays: account.relays.read, writeRelays: account.relays.write, ownRelays: account.relays.listed, known: account.contacts, appCount: account.follows.length })
          await c.reloadAccount()
          return { ok: true }
        } catch (e) { return { ok: false, error: String(e?.message ?? e) } }
      } },
    ],
  })

  // Send the scene when the web, the profiles or the address change, at most every SEND_EVERY_MS.
  const sentAt = useRef(0), pending = useRef(null), opened = useRef(null)
  useEffect(() => {
    const l = live.current
    if (!l) return
    const send = () => {
      pending.current = null; sentAt.current = Date.now()
      // The card to open is spent only on a scene that has the globe: a loading scene can't open it (it used to
      // be lost there, so #/wot/<hex> opened no card when the web wasn't built yet).
      const built = theirRoot ? !!theirs : !!web
      const first = built && open && opened.current !== open ? open : null
      if (built) opened.current = open
      const mine = new Set(follows)
      const whose = theirRoot ? getProfile(theirRoot)?.name || `${npubEncode(theirRoot).slice(0, 12)}…` : null
      const scene = theirRoot
        ? (theirs ? sceneOf(theirs, { profile: getProfile, status: "", open: first, whose, myFollows: mine }) : waitingScene(theirRoot, `Loading ${whose}'s follows…`))
        : web ? sceneOf(web, { profile: getProfile, status, open: first, myFollows: mine }) : waitingScene(me, status || "Loading your follows…")
      l.invoke({ archetype: "wot", action: "show", payload: { ...scene, whose, you: me } })
    }
    clearTimeout(pending.current)
    const wait = SEND_EVERY_MS - (Date.now() - sentAt.current)
    if (wait <= 0 || open !== opened.current) send(); else pending.current = setTimeout(send, wait)
    return () => clearTimeout(pending.current)
  }, [web, theirs, theirRoot, profilesIn, status, open, ready, follows.length])

  return (
    <main class="screen wot-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host wot-host" ref={host} />
    </main>
  )
}
