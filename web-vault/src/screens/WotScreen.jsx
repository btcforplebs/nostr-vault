// The Web of Trust tab, as the iPhone's globe: you in the middle, your follows round you, then the extended network,
// then further out (screens/WotGlobe.jsx). Tap someone for their trust card; My Web lists everyone in your web.
// The web comes from your follows' contact lists (net/wot.js); the globe's maths is net/wot-globe.js.
import { useEffect, useMemo, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { BlockDialog } from "../components/Moderation.jsx"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { setFollow } from "../net/follows.js"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPathText, FURTHER_CAP, EXTENDED_CAP, EXTENDED_MIN } from "../net/wot.js"
import { layout, outerFaces, pictured } from "../net/wot-globe.js"
import { WotGlobe } from "./WotGlobe.jsx"

if (import.meta.env) import("../styles/wot.css")

const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
const LAYER_LABEL = { me: "You", follow: "You follow", extended: "Extended network", further: "Further out" }
const LAYER_SHORT = { me: "You", follow: "Follow", extended: "Extended", further: "Further" }

export function WotScreen({ ctx }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const follows = account.follows
  const { blocked } = useBlocks(ctx)
  const [lists, setLists] = useState(null) // Map once the follows' lists are in
  const [status, setStatus] = useState("")
  const [view, setView] = useState("map") // "map" | "list"
  const [picked, setPicked] = useState(null) // pubkey of the open trust card
  const [centre, setCentre] = useState(null) // pubkey to turn to the front of the globe
  const [missing, setMissing] = useState(0) // follows whose list didn't come back
  const [round, setRound] = useState(0) // Try again

  useEffect(() => {
    if (!follows.length) { setStatus(""); return }
    if (!navigator.onLine) { setStatus("Your web needs the network: your follows' contact lists aren't kept in this browser."); return }
    let live = true
    setStatus(`Reading your ${follows.length} follows' lists…`)
    followLists(me, follows, round ? { retryMs: 0 } : {})
      .then(l => { if (live) { setLists(l); setMissing(missingLists(follows)); setStatus("") } })
    fetchProfiles(vault, follows, uniq([...account.relays.read, ...DEFAULT_RELAYS])).catch(() => {})
    return () => { live = false }
  }, [me, follows.length, round])

  // Built once per set of lists; blocking or unblocking only filters it (buildWeb reads every list, filterWeb doesn't).
  const built = useMemo(() => (lists ? buildWeb(me, follows, lists) : null), [lists, follows.length])
  const web = useMemo(() => (built ? filterWeb(built, lists, blocked) : null), [built, blocked])
  const shown = useMemo(() => (web ? { extended: shownByKey(web.extended, EXTENDED_CAP), further: shownByKey(web.further, FURTHER_CAP) } : null), [web])
  // Faces past your follows: the candidates' profiles are fetched (strangers', so kept in memory only), and the first
  // with a picture become faces as their profiles arrive.
  const candidates = useMemo(() => (web ? outerFaces(web) : []), [web])
  useEffect(() => { if (candidates.length) fetchProfiles(vault, candidates, uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {}) }, [candidates])
  const [profilesIn, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  const faceKey = useMemo(() => pictured(candidates, pk => !!getProfile(pk)?.picture).join(), [candidates, profilesIn])
  const nodes = useMemo(() => (web ? layout({ ...web, extended: shown.extended }, shown.further, faceKey ? faceKey.split(",") : []) : null), [web, shown, faceKey])

  const pickFromList = pk => { setPicked(pk); setCentre(pk); setView("map") }

  return (
    <main class="screen wot">
      <header class="screen-head wot-head">
        <h2>Web of Trust</h2>
        <div class="segmented wot-views" role="tablist" aria-label="View">
          <button role="tab" aria-selected={view === "map"} class={view === "map" ? "on" : ""} onClick={() => setView("map")}>Globe</button>
          <button role="tab" aria-selected={view === "list"} class={view === "list" ? "on" : ""} onClick={() => setView("list")}>My Web</button>
        </div>
      </header>
      {status && <div class="status-line">{status}</div>}
      {!status && missing > 0 && web && (
        <div class="status-line">
          {missing === 1 ? "1 of your follows' lists didn't arrive" : `${missing} of your follows' lists didn't arrive`}, so part of your web is missing.{" "}
          <button type="button" class="small" onClick={() => setRound(r => r + 1)}>Try again</button>
        </div>
      )}
      {!follows.length ? <p class="empty">{account.loaded ? "Follow someone to see your web: it's built from the people you follow and who they follow." : "Loading your follows…"}</p>
        : !web ? <p class="empty">{status ? "" : "Opening your web…"}</p>
        : view === "map"
          ? <WotGlobe web={web} nodes={nodes} picked={picked} onPick={setPicked} centre={centre} onCentred={() => setCentre(null)} capped={web.extended.length > shown.extended.length || web.further.length > shown.further.length} />
          : <MyWeb ctx={ctx} web={web} onPick={pickFromList} />}
      {picked && web && <TrustCard ctx={ctx} web={web} pubkey={picked} onPick={setPicked} onClose={() => setPicked(null)} />}
    </main>
  )
}

/** The trust card: who links you, the trust path, and Profile / Follow / Message / Block. */
function TrustCard({ ctx, web, pubkey, onPick, onClose }) {
  const { vault, account, session, signer } = ctx
  const [, bump] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [blocking, setBlocking] = useState(false)
  const { blocked } = useBlocks(ctx)
  const layer = web.layerOf(pubkey)
  const by = web.linkers.get(pubkey) ?? []
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  useEffect(() => {
    setErr("")
    // Your follows' names and pictures are kept; a stranger's stay in memory.
    fetchProfiles(vault, [pubkey], uniq([...account.relays.read, ...DEFAULT_RELAYS]), { save: layer === "follow" }).catch(() => {})
  }, [pubkey])
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
      <p class="wot-path">{blocked.has(pubkey) ? "You blocked this person." : trustPathText(web, pubkey, nameOf)}</p>
      {by.length > 0 && layer === "follow" && <p class="muted small wot-linkers-note">{by.length === 1 ? "1 of your follows follows them too" : `${by.length} of your follows follow them too`}</p>}
      {by.length > 0 && (
        <div class="wot-linkers" aria-label="Who links you">
          {by.slice(0, 8).map(f => <button key={f} type="button" class="wot-linker" title={nameOf(f)} aria-label={`Show ${nameOf(f)}`} onClick={() => onPick(f)}><Avatar pubkey={f} size={28} /></button>)}
          {by.length > 8 && <span class="muted small">+{by.length - 8}</span>}
        </div>
      )}
      {!isMe && (
        <div class="wot-actions">
          <a class="button small" href={`#/profile/${pubkey}`}>Profile</a>
          <button type="button" class={iFollow ? "small" : "small primary"} disabled={busy || !account.loaded} onClick={toggle}>
            {busy ? (signer.method === "nip46" ? "Waiting for your signer…" : "…") : iFollow ? "Unfollow" : "Follow"}
          </button>
          <a class="button small" href={`#/dm/${pubkey}`}>Message</a>
          {!blocked.has(pubkey) && <button type="button" class="small danger" onClick={() => setBlocking(true)}>Block</button>}
        </div>
      )}
      {err && <p class="error small" role="alert">{err}</p>}
      {blocking && <BlockDialog ctx={ctx} pubkey={pubkey} name={nameOf(pubkey)} onClose={() => setBlocking(false)} />}
    </section>
  )
}

const PAGE = 100
const FILTERS = [["all", "All"], ["follow", "Follows"], ["extended", "Extended"], ["further", "Further out"]]

/** My Web: everyone in your web, most-linked first, filtered by layer or by a name, a hundred at a time. */
function MyWeb({ ctx, web, onPick }) {
  const [filter, setFilter] = useState("all")
  const [q, setQ] = useState("")
  const [shown, setShown] = useState(PAGE)
  const [, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  const byLinks = (a, b) => (web.linkers.get(b)?.length ?? 0) - (web.linkers.get(a)?.length ?? 0)
  const all = useMemo(() => {
    const pick = { follow: [...web.follows].sort(byLinks), extended: web.extended, further: web.further }
    return filter === "all" ? [...pick.follow, ...pick.extended, ...pick.further] : pick[filter]
  }, [web, filter])
  const needle = q.trim().toLowerCase()
  const list = needle
    ? all.filter(pk => pk.startsWith(needle) || npubEncode(pk).startsWith(needle) || (getProfile(pk)?.name ?? "").toLowerCase().includes(needle) || (getProfile(pk)?.nip05 ?? "").toLowerCase().includes(needle))
    : all
  const page = list.slice(0, shown)
  useEffect(() => { setShown(PAGE) }, [filter, needle])
  useEffect(() => {
    const strangers = page.filter(pk => web.layerOf(pk) !== "follow")
    if (strangers.length) fetchProfiles(ctx.vault, strangers, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS]), { save: false }).catch(() => {})
  }, [page.join()])
  const counts = { all: web.follows.length + web.extended.length + web.further.length, follow: web.follows.length, extended: web.extended.length, further: web.further.length }
  return (
    <div class="wot-list">
      <p class="muted small wot-list-note">Built from the contact lists of the {web.follows.length} people you follow. Extended network: followed by {EXTENDED_MIN} or more of them.</p>
      <div class="wot-filters" role="tablist" aria-label="Show">
        {FILTERS.map(([id, label]) => <button key={id} role="tab" aria-selected={filter === id} class={filter === id ? "on" : ""} onClick={() => setFilter(id)}>{label} <span class="muted">{counts[id].toLocaleString()}</span></button>)}
      </div>
      <input class="wot-search" type="search" value={q} onInput={e => setQ(e.currentTarget.value)} placeholder="Find a name, npub or key" aria-label="Find in your web" autocapitalize="off" autocorrect="off" spellcheck={false} />
      {!page.length ? <p class="empty">{needle ? "Nobody in your web matches. Names only match once they've loaded." : "Nobody here yet."}</p>
        : page.map(pk => {
            const n = web.linkers.get(pk)?.length ?? 0, layer = web.layerOf(pk)
            const sub = `${layer === "follow" && web.followsMe.has(pk) ? "Follows you · " : ""}${n} of your follows follow them`
            return (
              <button key={pk} type="button" class="person-row wot-row" onClick={() => onPick(pk)}>
                <Avatar pubkey={pk} size={40} />
                <span class="person-names"><AuthorName pubkey={pk} /><span class="person-sub">{sub}</span></span>
                {filter === "all" && <span class={`wot-layer ${layer}`}>{LAYER_SHORT[layer]}</span>}
              </button>
            )
          })}
      {list.length > shown && <button class="more" onClick={() => setShown(s => s + PAGE)}>Show more ({(list.length - shown).toLocaleString()} left)</button>}
    </div>
  )
}
