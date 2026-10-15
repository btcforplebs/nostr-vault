// The Web of Trust tab, as the iPhone's 2D map (build 32): a big open map centred on you that you drag around (with
// momentum), zoom with a pinch or the wheel, and double-click to come back to you. Your follows are near, then the
// extended network, then further out. Tap someone for their trust card; My Web lists everyone in your web.
// The web comes from your follows' contact lists (net/wot.js); the maths is net/wot-map.js. Only what's on screen is
// drawn, so a big web stays fast.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { BlockDialog } from "../components/Moderation.jsx"
import { fetchProfiles, getProfile, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { setFollow } from "../net/follows.js"
import { followLists, missingLists, buildWeb, filterWeb, shownByKey, trustPathText, FURTHER_CAP, EXTENDED_CAP, EXTENDED_MIN } from "../net/wot.js"
import {
  layout, newCamera, moving, pan, fling, zoomBy, home, glideTo, step, visible, hit, sizes, unit, zoneEdges,
} from "../net/wot-map.js"

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
  const [centre, setCentre] = useState(null) // pubkey to glide to on the map
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
  const nodes = useMemo(() => (web ? layout({ ...web, extended: shown.extended }, shown.further) : null), [web, shown])

  const pickFromList = pk => { setPicked(pk); setCentre(pk); setView("map") }

  return (
    <main class="screen wot">
      <header class="screen-head wot-head">
        <h2>Web of Trust</h2>
        <div class="segmented wot-views" role="tablist" aria-label="View">
          <button role="tab" aria-selected={view === "map"} class={view === "map" ? "on" : ""} onClick={() => setView("map")}>Map</button>
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
          ? <WotMap web={web} nodes={nodes} picked={picked} onPick={setPicked} centre={centre} onCentred={() => setCentre(null)} capped={web.extended.length > shown.extended.length || web.further.length > shown.further.length} />
          : <MyWeb ctx={ctx} web={web} onPick={pickFromList} />}
      {picked && web && <TrustCard ctx={ctx} web={web} pubkey={picked} onPick={setPicked} onClose={() => setPicked(null)} />}
    </main>
  )
}

/** The map: a canvas drawn only when something changed, and only what's on screen. */
function WotMap({ web, nodes, picked, onPick, centre, onCentred, capped }) {
  const box = useRef(null), canvas = useRef(null)
  const cam = useRef(newCamera())
  const size = useRef({ w: 0, h: 0 })
  const drawn = useRef([])
  const frame = useRef(0), last = useRef(0)
  const images = useRef(new Map()) // picture url -> a small round bitmap of it | "loading" | "failed"
  const pointers = useRef(new Map())
  const gesture = useRef(null)
  const pickedRef = useRef(picked)
  pickedRef.current = picked

  const draw = () => {
    const c = canvas.current
    if (!c) return
    const { w, h } = size.current
    const dpr = globalThis.devicePixelRatio || 1
    const g = c.getContext("2d")
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, w, h)
    const k = cam.current
    const u = unit(w, h) * k.zoom, cx = w / 2 + k.offset[0], cy = h / 2 + k.offset[1]
    const sz = sizes(k.zoom)

    // Zone edges: faint dashed rings, no rim.
    g.save(); g.setLineDash([2, 6]); g.lineWidth = 0.6; g.strokeStyle = "rgb(255 255 255 / .10)"
    for (const r of zoneEdges()) { g.beginPath(); g.arc(cx, cy, r * u, 0, 2 * Math.PI); g.stroke() }
    g.restore()

    const vis = visible(nodes, k, w, h)
    drawn.current = vis
    // Lines: you to each follow, only where the line's box meets the screen (a line to someone just off screen still
    // slides in). One faint stroke for all of them.
    g.beginPath()
    for (const n of nodes) {
      if (n.layer !== "follow") continue
      const sx = cx + n.x * u, sy = cy + n.y * u
      if (Math.max(cx, sx) < 0 || Math.min(cx, sx) > w || Math.max(cy, sy) < 0 || Math.min(cy, sy) > h) continue
      g.moveTo(cx, cy); g.lineTo(sx, sy)
    }
    g.lineWidth = 0.6; g.strokeStyle = "rgb(230 115 38 / .16)"; g.stroke()

    // Dots: further out, then the extended network, one path each.
    for (const [layer, colour] of [["further", "rgb(255 255 255 / .28)"], ["extended", "rgb(51 204 153 / .75)"]]) {
      const r = sz[layer]
      g.beginPath()
      for (const d of vis) if (d.node.layer === layer) { g.moveTo(d.sx + r, d.sy); g.arc(d.sx, d.sy, r, 0, 2 * Math.PI) }
      g.fillStyle = colour; g.fill()
    }
    // Faces: your follows, then you on top.
    for (const d of vis) if (d.node.layer === "follow") face(g, d.node.pk, d.sx, d.sy, sz.follow, false)
    face(g, web.me, cx, cy, sz.me, true)
    // The person whose card is open.
    const p = pickedRef.current && vis.find(d => d.node.pk === pickedRef.current)
    if (p) {
      const r = p.node.layer === "me" ? sz.me : p.node.layer === "follow" ? sz.follow : Math.max(6, sz[p.node.layer] * 2.5)
      g.beginPath(); g.arc(p.sx, p.sy, r + 3, 0, 2 * Math.PI); g.lineWidth = 2; g.strokeStyle = "#fa9447"; g.stroke()
    }
  }

  // A face: the profile picture once it has loaded (asked for only when the face is on screen and big enough to
  // see), a coloured disc until then, as Avatar draws it. Each picture is drawn once into a small round bitmap, and the
  // frames draw that: a full-size photo scaled down every frame is what makes a zoomed-out map slow.
  const face = (g, pk, x, y, r, ring) => {
    const url = getProfile(pk)?.picture
    const img = url && images.current.get(url)
    if (url && !img && r >= 6) {
      images.current.set(url, "loading")
      const im = new Image()
      im.decoding = "async"; im.referrerPolicy = "no-referrer"
      im.onload = () => { images.current.set(url, roundBitmap(im)); request() }
      im.onerror = () => images.current.set(url, "failed")
      im.src = url
    }
    if (img && typeof img === "object") g.drawImage(img, x - r, y - r, 2 * r, 2 * r)
    else { g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI); g.fillStyle = `hsl(${parseInt(pk.slice(0, 6), 16) % 360} 45% 35%)`; g.fill() }
    g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI)
    g.lineWidth = ring ? 2.5 : 1; g.strokeStyle = ring ? "#e67326" : "rgb(0 0 0 / .6)"; g.stroke()
  }

  // One frame at a time, and only while something moves or changed.
  const request = () => { if (!frame.current) frame.current = requestAnimationFrame(tick) }
  const tick = t => {
    frame.current = 0
    const dt = last.current ? Math.min(0.05, (t - last.current) / 1000) : 1 / 60
    const { w, h } = size.current
    if (moving(cam.current)) cam.current = step(cam.current, dt, w, h)
    draw()
    if (moving(cam.current)) { last.current = t; request() } else last.current = 0
  }

  // Size: the canvas fills its box at the screen's pixel density.
  useEffect(() => {
    const ro = new ResizeObserver(([e]) => {
      const w = Math.round(e.contentRect.width), h = Math.round(e.contentRect.height)
      const dpr = globalThis.devicePixelRatio || 1
      size.current = { w, h }
      canvas.current.width = w * dpr; canvas.current.height = h * dpr
      request()
    })
    ro.observe(box.current)
    const off = onProfiles(request) // names and pictures arriving
    return () => { ro.disconnect(); off(); cancelAnimationFrame(frame.current); frame.current = 0 }
  }, [])
  useEffect(request, [nodes, picked])
  useEffect(() => {
    if (!centre) return
    const n = nodes.find(x => x.pk === centre)
    if (n) { cam.current = glideTo(cam.current, n.x, n.y, size.current.w, size.current.h); request() }
    onCentred()
  }, [centre, nodes])

  // Gestures: one finger or the mouse drags (a flick carries on), two fingers pinch, the wheel zooms about the
  // pointer, a double-click goes home, a tap opens a card.
  const local = e => { const r = canvas.current.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] }
  const down = e => {
    canvas.current.setPointerCapture?.(e.pointerId)
    pointers.current.set(e.pointerId, local(e))
    cam.current = { ...cam.current, velocity: [0, 0], homing: false, target: null }
    const [x, y] = local(e)
    gesture.current = { startX: x, startY: y, moved: 0, samples: [[performance.now(), x, y]], pinch: pointers.current.size === 2 ? pinchState() : null }
  }
  const pinchState = () => {
    const [a, b] = [...pointers.current.values()]
    return { dist: Math.hypot(a[0] - b[0], a[1] - b[1]), mid: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2] }
  }
  const move = e => {
    if (!pointers.current.has(e.pointerId) || !gesture.current) return
    const prev = pointers.current.get(e.pointerId), now = local(e)
    pointers.current.set(e.pointerId, now)
    const { w, h } = size.current, gs = gesture.current
    if (pointers.current.size >= 2) {
      const p = pinchState(), was = gs.pinch ?? p
      cam.current = pan(cam.current, p.mid[0] - was.mid[0], p.mid[1] - was.mid[1], w, h)
      if (was.dist > 0) cam.current = zoomBy(cam.current, p.dist / was.dist, w, h, p.mid[0], p.mid[1])
      gs.pinch = p; gs.moved = Infinity
    } else {
      cam.current = pan(cam.current, now[0] - prev[0], now[1] - prev[1], w, h)
      gs.moved = Math.max(gs.moved, Math.hypot(now[0] - gs.startX, now[1] - gs.startY))
      gs.samples.push([performance.now(), now[0], now[1]])
      if (gs.samples.length > 6) gs.samples.shift()
    }
    request()
  }
  const up = e => {
    pointers.current.delete(e.pointerId)
    const gs = gesture.current
    if (!gs) return
    if (pointers.current.size) { gs.pinch = pointers.current.size === 2 ? pinchState() : null; return }
    gesture.current = null
    if (gs.moved < 6) {
      const [x, y] = local(e)
      const n = hit(drawn.current, x, y, cam.current.zoom)
      onPick(n ? n.pk : null)
      return
    }
    // Speed over the last ~80 ms of the drag.
    const t = performance.now(), recent = gs.samples.filter(s => t - s[0] < 80)
    if (recent.length >= 2) {
      const [t0, x0, y0] = recent[0], [t1, x1, y1] = recent.at(-1)
      const dt = Math.max(0.008, (t1 - t0) / 1000)
      cam.current = fling(cam.current, (x1 - x0) / dt, (y1 - y0) / dt)
      request()
    }
  }
  const wheel = e => {
    e.preventDefault()
    const [x, y] = local(e)
    // A trackpad pinch arrives as a wheel with ctrlKey and small deltas; a mouse wheel as bigger ones.
    const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0018))
    cam.current = zoomBy(cam.current, factor, size.current.w, size.current.h, x, y)
    request()
  }
  useEffect(() => {
    const c = canvas.current
    c.addEventListener("wheel", wheel, { passive: false }) // passive listeners can't stop the page scrolling
    return () => c.removeEventListener("wheel", wheel)
  }, [])
  const key = e => {
    const { w, h } = size.current, stepPx = 80
    const moves = { ArrowLeft: [stepPx, 0], ArrowRight: [-stepPx, 0], ArrowUp: [0, stepPx], ArrowDown: [0, -stepPx] }
    if (moves[e.key]) cam.current = pan(cam.current, ...moves[e.key], w, h)
    else if (e.key === "+" || e.key === "=") cam.current = zoomBy(cam.current, 1.25, w, h)
    else if (e.key === "-") cam.current = zoomBy(cam.current, 0.8, w, h)
    else if (e.key === "0" || e.key === "Home") cam.current = home(cam.current)
    else return
    e.preventDefault(); request()
  }
  const goHome = () => { cam.current = home(cam.current); request() }

  return (
    <div class="wot-map" ref={box}>
      <canvas ref={canvas} tabIndex={0} role="img"
        aria-label={`Map of your web: ${web.follows.length} follows, ${web.extended.length} in your extended network, ${web.further.length} further out. Drag to move, scroll or pinch to zoom, double-click to come back to you.`}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onDblClick={goHome} onKeyDown={key} />
      <div class="wot-legend" aria-hidden="true">
        <span><i class="dot follow" />{web.follows.length} follows</span>
        <span><i class="dot extended" />{web.extended.length} extended</span>
        <span><i class="dot further" />{web.further.length} further out</span>
        {capped && <span>Up to {FURTHER_CAP.toLocaleString()} of each drawn; My Web lists all</span>}
      </div>
      <button type="button" class="small wot-home" onClick={goHome} aria-label="Back to you">Me</button>
    </div>
  )
}

/** BITMAP px square, round, cover-cropped: big enough for the largest face at the screen's density. */
const BITMAP = 96
function roundBitmap(im) {
  const c = document.createElement("canvas")
  c.width = c.height = BITMAP
  const g = c.getContext("2d")
  const side = Math.min(im.naturalWidth || BITMAP, im.naturalHeight || BITMAP)
  const sx = ((im.naturalWidth || side) - side) / 2, sy = ((im.naturalHeight || side) - side) / 2
  g.beginPath(); g.arc(BITMAP / 2, BITMAP / 2, BITMAP / 2, 0, 2 * Math.PI); g.clip()
  g.drawImage(im, sx, sy, side, side, 0, 0, BITMAP, BITMAP)
  return c
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
