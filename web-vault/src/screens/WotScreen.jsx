// The Web of Trust tab, as the iPhone's globe: you in the middle, your follows round you, then the people your
// follows vouch for, then further out (screens/WotGlobe.jsx). Tap someone for their trust card; My Web lists everyone
// in your web. "See their web" puts someone in the middle with the people they follow round them, one step further
// along a trail of breadcrumbs back to you (TrustWebView+Actions, +Breadcrumbs). The address says who is in the
// middle: #/wot is you (the tab takes you back), #/wot/<hex> is them (a profile's Web of Trust button, as the
// iPhone's "Open in WoT"). Webs come from contact lists (net/wot.js); the globe's maths is net/wot-globe.js.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { BlockDialog, UnblockDialog } from "../components/Moderation.jsx"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { setFollow, followsOf } from "../net/follows.js"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPath, trustPathText, layerCounts, LAYERS, FURTHER_CAP, EXTENDED_CAP, EXTENDED_MIN } from "../net/wot.js"
import { layout, outerFaces, pictured } from "../net/wot-globe.js"
import { WotGlobe } from "./WotGlobe.jsx"
import { brainstormLink, fetchPersonLists } from "../net/person.js"

if (import.meta.env) import("../styles/wot.css")

const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
const LAYER_LABEL = { me: "You", follow: "You follow", extended: "Vouched", further: "Further out" }
const LAYER_SHORT = { me: "You", follow: "Follow", extended: "Vouched", further: "Further" }
/** "15K", as the iPhone's layer picker counts. */
const compact = n => n.toLocaleString(undefined, { notation: "compact" })

export function WotScreen({ ctx, pubkey }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const follows = account.follows
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null) // Map once the follows' lists are in
  const [status, setStatus] = useState("")
  const [view, setView] = useState("map") // "map" | "list"
  const [layer, setLayer] = useState("everyone") // the layer picker (wot.js LAYERS); My Web lists the same layer
  const [picked, setPicked] = useState(null) // pubkey of the open trust card
  const [centre, setCentre] = useState(null) // pubkey to turn to the front of the globe
  const [missing, setMissing] = useState(0) // follows whose list didn't come back
  const [round, setRound] = useState(0) // Try again
  const [crumbs, setCrumbs] = useState([me]) // the trail: you, then each person whose web you went on to
  const [frames, setFrames] = useState(() => new Map()) // someone on the trail -> { ring, listFound, lists }
  const stepping = useRef(null) // who See their web is moving onto, so the address change extends the trail
  const root = crumbs.at(-1)

  useEffect(() => {
    if (!follows.length) { setStatus(""); return }
    if (!navigator.onLine) { setStatus("Your web needs the network: your follows' contact lists aren't kept in this browser."); return }
    let live = true
    setStatus("Mapping your web…")
    followLists(me, follows, round ? { retryMs: 0 } : {})
      .then(l => { if (live) { setLists(l); setMissing(missingLists(follows)); setStatus("") } })
    fetchProfiles(vault, follows, uniq([...account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
    return () => { live = false }
  }, [me, follows.length, round])

  // Built once per set of lists; blocking or unblocking only filters it (buildWeb reads every list, filterWeb doesn't).
  const built = useMemo(() => (lists ? buildWeb(me, follows, lists) : null), [lists, follows.length])
  const web = useMemo(() => (built ? filterWeb(built, lists, blocked) : null), [built, blocked])

  // The address moved: #/wot is you, #/wot/<hex> someone. A step back along the trail cuts it there; See their web
  // adds a step; anything else (a profile's Web of Trust button) starts a new trail from you, card and My Web put away.
  useEffect(() => {
    const target = pubkey && pubkey !== me ? pubkey : null
    const from = stepping.current
    stepping.current = null
    setCrumbs(c => {
      if (!target) return [me]
      const i = c.indexOf(target)
      return i >= 0 ? c.slice(0, i + 1) : from === target ? [...c, target] : [me, target]
    })
    if (target && from !== target) { setPicked(null); setView("map") }
  }, [pubkey, me])
  const goTo = pk => { location.hash = pk === me ? "#/wot" : `#/wot/${pk}` }
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
  const whose = root === me ? null : nameOf(root)
  const globeStatus = root === me ? "" : !frame?.ring ? `Loading ${whose}'s follows…`
    : !frame.listFound ? `No relay had ${whose}'s follow list.` : !frame.lists ? `Mapping ${whose}'s web…` : ""

  const shown = useMemo(() => (globeWeb ? { extended: shownByKey(globeWeb.extended, EXTENDED_CAP), further: shownByKey(globeWeb.further, FURTHER_CAP) } : null), [globeWeb])
  // Faces past the follows: the candidates' profiles are fetched (strangers', so kept in memory only), and the first
  // with a picture become faces as their profiles arrive.
  const candidates = useMemo(() => (globeWeb ? outerFaces(globeWeb) : []), [globeWeb])
  useEffect(() => { if (candidates.length) fetchProfiles(vault, candidates, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {}) }, [candidates])
  const [profilesIn, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  const faceKey = useMemo(() => pictured(candidates, pk => !!getProfile(pk)?.picture).join(), [candidates, profilesIn])
  const nodes = useMemo(() => (globeWeb ? layout({ ...globeWeb, extended: shown.extended }, shown.further, faceKey ? faceKey.split(",") : []) : null), [globeWeb, shown, faceKey])
  // The open card's trust path, traced on your own globe.
  const path = useMemo(() => (picked && root === me ? trustPath(web, picked)?.all ?? [] : []), [picked, web, root])

  // A tap on a face turns the globe to it and opens its card; on you, on the open card's face or on nothing, it closes
  // the card (TrustWebView.tapped).
  const tapped = pk => {
    if (!pk || pk === me || pk === picked) { setPicked(null); return }
    setPicked(pk); setCentre(pk)
  }
  const pickFromList = pk => { setPicked(pk); setCentre(pk); setView("map") }
  const counts = web ? layerCounts(web) : null
  const line = view === "map" && globeStatus ? globeStatus : status

  return (
    <main class="screen wot">
      <header class="screen-head wot-head">
        <h2>Web of Trust</h2>
        <div class="segmented wot-views" role="tablist" aria-label="View">
          <button role="tab" aria-selected={view === "map"} class={view === "map" ? "on" : ""} onClick={() => setView("map")}>Globe</button>
          <button role="tab" aria-selected={view === "list"} class={view === "list" ? "on" : ""} onClick={() => setView("list")}>My Web</button>
        </div>
      </header>
      {view === "map" && crumbs.length > 1 && (
        <nav class="wot-filters" aria-label="Whose web">
          {crumbs.map((pk, i) => [
            i > 0 && <span key={`${pk}>`} class="muted" style={{ alignSelf: "center" }} aria-hidden="true">›</span>,
            <button key={pk} type="button" class={i === crumbs.length - 1 ? "chip on" : "chip"} aria-current={i === crumbs.length - 1 ? "step" : undefined}
              title={i === crumbs.length - 1 ? undefined : "Goes back to this step"} onClick={() => goTo(pk)}>
              <Avatar pubkey={pk} size={22} />{pk === me ? "You" : nameOf(pk)}
            </button>,
          ])}
        </nav>
      )}
      {view === "map" && root === me && counts && <LayerPicker layer={layer} counts={counts} onPick={setLayer} />}
      {line && <div class="status-line">{line}</div>}
      {!status && missing > 0 && web && root === me && (
        <div class="status-line">
          {missing === 1 ? "1 of your follows' lists didn't arrive" : `${missing} of your follows' lists didn't arrive`}, so part of your web is missing.{" "}
          <button type="button" class="small" onClick={() => setRound(r => r + 1)}>Try again</button>
        </div>
      )}
      {!follows.length && (root === me || view === "list") ? <p class="empty">{account.loaded ? "Follow someone to see your web: it's built from the people you follow and who they follow." : "Loading your follows…"}</p>
        : view === "list" ? (web ? <MyWeb ctx={ctx} web={web} layer={layer} onLayer={setLayer} onPick={pickFromList} /> : <p class="empty">{status ? "" : "Mapping your web…"}</p>)
        : globeWeb
          ? <WotGlobe key={root} web={globeWeb} nodes={nodes} picked={picked} onPick={tapped} centre={centre} onCentred={() => setCentre(null)}
              capped={globeWeb.extended.length > shown.extended.length || globeWeb.further.length > shown.further.length}
              layer={root === me ? layer : "everyone"} path={path} whose={whose} />
          : <p class="empty">{status || globeStatus ? "" : "Mapping your web…"}</p>}
      {picked && web && <TrustCard ctx={ctx} web={web} built={built} root={root} pubkey={picked} onPick={pickFromList} onSeeWeb={seeTheirWeb} onClose={() => setPicked(null)} />}
    </main>
  )
}

/** Which part of your web the globe lights (TrustWebView+WOTTabBar layerMenu): the iPhone's names, with counts. */
function LayerPicker({ layer, counts, onPick }) {
  return (
    <div class="wot-filters" role="radiogroup" aria-label="Showing">
      {LAYERS.map(([id, title]) => (
        <button key={id} type="button" role="radio" aria-checked={layer === id} class={layer === id ? "on" : ""} onClick={() => onPick(id)}>
          {title} <span class="muted">{compact(counts[id])}</span>
        </button>
      ))}
    </div>
  )
}

/** The trust card (TrustWebView+TrustCard): who they are, the people you follow who follow them, and Follow, Profile,
 *  See their web, then Message, Brainstorm and Block or Unblock behind "…", in the iPhone's order. */
function TrustCard({ ctx, web, built, root, pubkey, onPick, onSeeWeb, onClose }) {
  const { vault, account, session, signer } = ctx
  const [, bump] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [dialog, setDialog] = useState(null) // "block" | "unblock"
  const { blocked } = useBlocks(ctx)
  const isBlocked = blocked.has(pubkey)
  // A blocked person is out of your web; their line is still traced, from the web before blocks.
  const pathWeb = isBlocked ? built : web
  const layer = pathWeb.layerOf(pubkey)
  const by = pathWeb.linkers.get(pubkey) ?? []
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  useEffect(() => {
    setErr("")
    // Your follows' names and pictures are kept; a stranger's stay in memory.
    fetchProfiles(vault, [pubkey], uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: layer === "follow" }).catch(() => {})
  }, [pubkey])
  // Blocking someone puts their card away, as on the iPhone.
  const wasBlocked = useRef(isBlocked)
  useEffect(() => { if (isBlocked && !wasBlocked.current) onClose(); wasBlocked.current = isBlocked }, [isBlocked])
  const iFollow = account.follows.includes(pubkey)
  const isMe = pubkey === session.pubkey
  const toggle = async () => {
    setBusy(true); setErr("")
    try {
      await setFollow({ vault, signer, pubkey: session.pubkey, target: pubkey, follow: !iFollow,
        readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
      await ctx.reloadAccount()
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const p = getProfile(pubkey)
  return (
    <section class="wot-card" role="dialog" aria-label={`Trust card: ${nameOf(pubkey)}`}>
      <button type="button" class="wot-card-close" aria-label="Close" onClick={onClose}>×</button>
      <div class="wot-card-head">
        <Avatar pubkey={pubkey} size={48} ring={isMe} />
        <div class="wot-card-names">
          <div class="wot-card-name"><AuthorName pubkey={pubkey} /></div>
          <div class="muted small">{p?.nip05?.replace(/^_@/, "") || npubEncode(pubkey).slice(0, 16) + "…"}</div>
        </div>
        {layer && <span class={`wot-layer ${layer}`}>{LAYER_LABEL[layer]}</span>}
      </div>
      <p class="wot-path">{trustPathText(pathWeb, pubkey, nameOf)}</p>
      {by.length > 0 && layer === "follow" && <p class="muted small wot-linkers-note">{by.length === 1 ? "1 of your follows follows them too" : `${by.length} of your follows follow them too`}</p>}
      {by.length > 0 && (
        <div class="wot-linkers" aria-label="Who links you">
          {by.slice(0, 8).map(f => <button key={f} type="button" class="wot-linker" title={nameOf(f)} aria-label={`Show ${nameOf(f)}`} onClick={() => onPick(f)}><Avatar pubkey={f} size={28} /></button>)}
          {by.length > 8 && <span class="muted small">+{by.length - 8}</span>}
        </div>
      )}
      {!isMe && (
        <div class="wot-actions">
          <button type="button" class={iFollow ? "small" : "small primary"} disabled={busy || !account.loaded} onClick={toggle} aria-busy={busy || undefined}>
            {busy ? (signer.method === "nip46" ? "Waiting for your signer…" : "…") : iFollow ? "Unfollow" : "Follow"}
          </button>
          <a class="button small" href={`#/profile/${pubkey}`}>Profile</a>
          {/* The iPhone's short label on a narrow card ("Their web"); its full name for screen readers. */}
          {pubkey !== root && <button type="button" class="small" aria-label="See their web" title={`Puts ${nameOf(pubkey)} in the middle, with the people they follow around them`} onClick={() => onSeeWeb(pubkey)}>Their web</button>}
          <CardMore pubkey={pubkey} blocked={isBlocked} onDialog={setDialog} />
        </div>
      )}
      {err && <p class="error small" role="alert">{err}</p>}
      {dialog === "block" && <BlockDialog ctx={ctx} pubkey={pubkey} name={nameOf(pubkey)} onClose={() => setDialog(null)} />}
      {dialog === "unblock" && <UnblockDialog ctx={ctx} pubkey={pubkey} name={nameOf(pubkey)} onClose={() => setDialog(null)} />}
    </section>
  )
}

/** The card's "…": Message, Open in Brainstorm, then Block or Unblock, the iPhone's menu in the note menu's classes. */
function CardMore({ pubkey, blocked, onDialog }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  const pick = fn => () => { setOpen(false); fn() }
  return (
    <span class="more-wrap" ref={ref}>
      <button type="button" class="small" aria-label="More" title="More" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12h.01M12 12h.01M19 12h.01" /></svg>
      </button>
      {open && (
        <div class="more-menu" role="menu">
          <button role="menuitem" onClick={pick(() => { location.hash = `#/dm/${pubkey}` })}>Message</button>
          <button role="menuitem" onClick={pick(() => open_(brainstormLink(pubkey)))}>Open in Brainstorm</button>
          <hr class="more-sep" />
          {blocked
            ? <button role="menuitem" onClick={pick(() => onDialog("unblock"))}>Unblock</button>
            : <button role="menuitem" class="danger" onClick={pick(() => onDialog("block"))}>Block</button>}
        </div>
      )}
    </span>
  )
}
const open_ = url => globalThis.open(url, "_blank", "noopener,noreferrer")

const PAGE = 100

/** My Web: everyone in your web, most-linked first, in the picker's layer or found by a name, a hundred at a time. */
function MyWeb({ ctx, web, layer, onLayer, onPick }) {
  const [q, setQ] = useState("")
  const [shown, setShown] = useState(PAGE)
  const [, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  const byLinks = (a, b) => (web.linkers.get(b)?.length ?? 0) - (web.linkers.get(a)?.length ?? 0)
  const all = useMemo(() => {
    const pick = { following: [...web.follows].sort(byLinks), close: web.extended, furtherOut: web.further }
    return layer === "everyone" ? [...pick.following, ...pick.close, ...pick.furtherOut] : pick[layer]
  }, [web, layer])
  const needle = q.trim().toLowerCase()
  const list = needle
    ? all.filter(pk => pk.startsWith(needle) || npubEncode(pk).startsWith(needle) || (getProfile(pk)?.name ?? "").toLowerCase().includes(needle) || (getProfile(pk)?.nip05 ?? "").toLowerCase().includes(needle))
    : all
  const page = list.slice(0, shown)
  useEffect(() => { setShown(PAGE) }, [layer, needle])
  useEffect(() => {
    const strangers = page.filter(pk => web.layerOf(pk) !== "follow")
    if (strangers.length) fetchProfiles(ctx.vault, strangers, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {})
  }, [page.join()])
  return (
    <div class="wot-list">
      <p class="muted small wot-list-note">Built from the contact lists of the {web.follows.length} people you follow. Vouched: followed by {EXTENDED_MIN} or more of them.</p>
      <LayerPicker layer={layer} counts={layerCounts(web)} onPick={onLayer} />
      <input class="wot-search" type="search" value={q} onInput={e => setQ(e.currentTarget.value)} placeholder="Find a name, npub or key" aria-label="Find in your web" autocapitalize="off" autocorrect="off" spellcheck={false} />
      {!page.length ? <p class="empty">{needle ? "Nobody in your web matches. Names only match once they've loaded." : "Nobody here yet."}</p>
        : page.map(pk => {
            const n = web.linkers.get(pk)?.length ?? 0, of = web.layerOf(pk)
            const sub = `${of === "follow" && web.followsMe.has(pk) ? "Follows you · " : ""}${n} of your follows follow them`
            return (
              <button key={pk} type="button" class="person-row wot-row" onClick={() => onPick(pk)}>
                <Avatar pubkey={pk} size={40} />
                <span class="person-names"><AuthorName pubkey={pk} /><span class="person-sub">{sub}</span></span>
                {layer === "everyone" && <span class={`wot-layer ${of}`}>{LAYER_SHORT[of]}</span>}
              </button>
            )
          })}
      {list.length > shown && <button class="more" onClick={() => setShown(s => s + PAGE)}>Show more ({(list.length - shown).toLocaleString()} left)</button>}
    </div>
  )
}
