// The Web of Trust globe, as the iPhone's: you in the middle, your follows' faces on the sphere round you, the
// extended network on the next shell out and everyone further out on a faint outer one, the most linked of them as
// faces too. Drag to spin it (a flick
// carries on), pinch or the wheel to zoom, double-click to come back to the start; tap a face for its trust card.
// Faces fade and shrink rolling toward the rim and round the back, and give up their seat to a nearer face instead of
// piling up. Only what's on screen is drawn, and nothing is drawn while the globe is still. The maths is
// net/wot-globe.js. `layer` is the picker's layer (LAYER_WEIGHTS): the rest of the globe goes out. `path` is the open
// card's bridges: threads run from the middle through each of them to the person whose card is open, and only they
// and that person stay faces. `lit` (a Set, or null for everyone) is who the filter and, on someone else's globe, your
// layer leave lit; the rest stay as dim stars. `whose` names the person in the middle when it isn't you (See their web),
// written under the middle face as "You" is on yours.
import { useEffect, useRef } from "preact/hooks"
import { getProfile, onProfiles } from "../net/profiles.js"
import { faceCache, FACE_PX } from "../net/face-cache.js"
import { fraction } from "../net/wot.js"
import {
  RADIUS, newCamera, moving, drag, flick, zoomBy, zoomNow, flyTo, facing, direction, home, step, projector, outline,
  faceShown, faceRadius, dotLight, seatFade, faceSize, seats, onScreen, hit, OUTER_ALPHA, LAYER_WEIGHTS, SIZE, STAR, RIM, starAlpha,
} from "../net/wot-globe.js"

/** New pictures a frame may start loading: a fast spin brings faces into seats faster than they need decoding at once;
 *  the rest show their coloured disc a frame or two longer. */
const LOADS_PER_FRAME = 8
const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
/** How bright someone a filter leaves out stays: still there, just back (TrustMap.StarLight.filteredOut). */
const DIMMED = 0.08
/** A face's own colour while it has no picture: the hue of its spot on the globe, as the iPhone tints it. */
const hueOf = pk => Math.round(fraction(pk, 0) * 360)
/** Pictures already drawn into small round bitmaps, kept across globes (see `images` below). */
const sharedImages = faceCache({ onDrop: e => { if (typeof e === "object") e.width = e.height = 0 } })

export function WotGlobe({ web, nodes, picked, onPick, centre, onCentred, layer = "everyone", lit = null, path = [], whose = null }) {
  const box = useRef(null), canvas = useRef(null)
  const cam = useRef(newCamera())
  const size = useRef({ w: 0, h: 0 })
  const drawn = useRef([])
  const fades = useRef(new Map()) // follow pk -> seat fade 0..1
  const fading = useRef(false)
  const frame = useRef(0), last = useRef(0)
  // picture url -> a small round bitmap of it | "loading" | "failed"; at most FACE_MAX kept (net/face-cache.js). Shared
  // by every globe, so coming back to the tab or moving onto someone's web doesn't load every picture again. A dropped
  // bitmap's pixels are released by shrinking its canvas, not left for the collector.
  const images = useRef(sharedImages)
  const pointers = useRef(new Map())
  const loadsLeft = useRef(0) // pictures this frame may still start loading
  const gesture = useRef(null)
  const pickedRef = useRef(picked)
  pickedRef.current = picked
  // What the frames draw, read when each frame is drawn: a frame loop started on an earlier render (faces still
  // fading in) would otherwise go on drawing that render's people after the web under it has filled in.
  const scene = useRef(null)
  scene.current = { web, nodes, weights: LAYER_WEIGHTS[layer] ?? LAYER_WEIGHTS.everyone, path, lit, label: whose ?? "You" }

  const draw = dt => {
    const c = canvas.current
    if (!c) return
    const { w, h } = size.current
    const dpr = globalThis.devicePixelRatio || 1
    const g = c.getContext("2d")
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, w, h)
    const k = cam.current, project = projector(k, w, h), reduce = reducedMotion()
    loadsLeft.current = LOADS_PER_FRAME
    images.current.frame() // pictures drawn from here on are on screen, and never dropped
    const { web, nodes, weights, path, lit, label } = scene.current
    // The open card's person and their bridges are lit whatever the layer or filter, and while they're traced only they
    // show as faces (GlobeScene traceTarget): everyone else steps back to a star.
    const target = pickedRef.current && pickedRef.current !== web.me ? pickedRef.current : null
    const traced = target && path.length ? new Set([target, ...path]) : null
    const pinned = pk => pk === target || !!traced?.has(pk)
    const shade = pk => (!lit || lit.has(pk) || pinned(pk) ? 1 : DIMMED)

    // Project everyone once; stars go into a few brightness bands per kind, so a big web is a handful of fills. A layer
    // the picker put out isn't drawn, and can't be tapped.
    const out = [], faces = []
    const bands = new Map() // "kind|weight|band" -> [p]
    for (const node of nodes) {
      if (node.layer === "me") continue
      const weight = pinned(node.pk) ? 1 : weights[node.layer] * shade(node.pk)
      if (!weight) continue
      const p = project(node.p)
      if (!p || !onScreen(p.x, p.y, w, h)) continue
      // While a path is traced its people are faces whether or not they had a seat as one (GlobeScene traceBridges).
      if (traced ? traced.has(node.pk) : node.face && shade(node.pk) === 1) {
        const lead = node.layer === "follow"
        const kind = node.pk === target ? "traced" : traced ? "bridge" : lead ? "follow" : "outer"
        faces.push({ pk: node.pk, node, kind, x: p.x, y: p.y, depth: p.depth, r: faceSize(kind === "traced" ? "traced" : lead ? "follow" : "outer", p, k.zoom),
          lead: lead || !!traced, alpha: Math.min(1, (lead || traced ? 1 : OUTER_ALPHA) * weight) })
        continue
      }
      const light = dotLight(p.depth)
      const kind = traced?.has(node.pk) ? "hot" : node.layer === "follow" ? "ring" : node.layer
      const key = `${kind}|${weight}|${Math.min(3, Math.floor((light - 0.35) / 0.65 * 4))}`
      const list = bands.get(key)
      if (list) list.push(p); else bands.set(key, [p])
      out.push({ node, x: p.x, y: p.y, depth: p.depth, face: false })
    }
    for (const [key, list] of bands) {
      const [kind, weight, b] = key.split("|"), star = STAR[kind], s0 = SIZE[kind === "hot" ? "ring" : kind]
      g.beginPath()
      for (const p of list) { const s = s0 * p.scale * Math.min(k.zoom, 1.8); g.moveTo(p.x + s, p.y); g.arc(p.x, p.y, s, 0, 2 * Math.PI) }
      g.fillStyle = `rgb(${star[0]} ${star[1]} ${star[2]} / ${Math.min(1, starAlpha(star, 0.35 + 0.65 * (+b + 0.5) / 4) * +weight)})`
      g.fill()
    }

    // Seats: who shows a face this frame, each fading in or out over a quarter second. You hold the middle seat, so a
    // face rolling across you fades rather than covering you.
    const meP = project([0, 0, 0])
    const me = { pk: web.me, node: nodes[0], kind: "me", x: meP.x, y: meP.y, depth: Infinity, r: faceSize("me", meP, k.zoom), lead: true, alpha: 1, shown: 1, me: true }
    const seated = seats([me, ...faces])
    const next = new Map()
    let still = true
    for (const f of faces) {
      const was = fades.current.get(f.pk) ?? 0 // a new face fades in
      const now = seatFade(was, seated.has(f.pk), dt, reduce)
      if (now !== (seated.has(f.pk) ? 1 : 0)) still = false
      next.set(f.pk, now)
      f.shown = faceShown(f.depth) * now
    }
    fades.current = next
    fading.current = !still

    // Back to front, you on top.
    const all = [...faces.sort((a, b) => a.depth - b.depth), me]

    // The glow behind the middle (GlobeScene: the accent at 0.32).
    const glow = g.createRadialGradient(me.x, me.y, 0, me.x, me.y, me.r * 3)
    glow.addColorStop(0, "rgb(230 115 38 / .32)"); glow.addColorStop(1, "rgb(230 115 38 / 0)")
    g.fillStyle = glow; g.beginPath(); g.arc(me.x, me.y, me.r * 3, 0, 2 * Math.PI); g.fill()

    // The open card's trust path, as the iPhone traces it: from the middle to each bridge showing (a faint inner leg),
    // then on to the person (the outer leg), warm amber over an orange glow.
    const at = new Map()
    for (const d of out) at.set(d.node.pk, d)
    for (const f of faces) at.set(f.pk, f)
    const to = target && at.get(target)
    if (to && traced) {
      const legs = []
      for (const pk of path) { const b = at.get(pk); if (b && b.depth >= -0.2 && (b.shown ?? 1) >= 0.3) legs.push(b) }
      const stroke = (width, colour, inner) => {
        g.beginPath()
        for (const b of legs) { if (inner) { g.moveTo(me.x, me.y); g.lineTo(b.x, b.y) } else { g.moveTo(b.x, b.y); g.lineTo(to.x, to.y) } }
        g.lineWidth = width; g.strokeStyle = colour; g.stroke()
      }
      stroke(3, "rgb(230 115 38 / .16)", true); stroke(3, "rgb(230 115 38 / .25)", false)
      stroke(0.8, "rgb(255 168 77 / .45)", true); stroke(1.3, "rgb(255 168 77 / .9)", false)
    }

    for (const f of all) {
      // A face losing its seat or rolling round the back fades into a star where it sits.
      if (!f.me && f.shown < 1) {
        const star = f.kind === "bridge" || f.kind === "traced" ? STAR.hot : f.kind === "follow" ? STAR.ring : STAR.extended
        g.beginPath(); g.arc(f.x, f.y, SIZE.ring * f.r / SIZE.follow, 0, 2 * Math.PI)
        g.fillStyle = `rgb(${star[0]} ${star[1]} ${star[2]} / ${starAlpha(star, dotLight(f.depth)) * (1 - f.shown)})`; g.fill()
      }
      // A picture is loaded only for a face that holds a seat (seats are bounded by the screen); a face fading out
      // still draws its picture if it's cached, so the cache never thrashes on a big web.
      if (f.shown > 0.01) face(g, f.pk, f.x, f.y, f.me ? f.r : faceRadius(f.r, f.shown), f.shown * f.alpha, f.kind, f.me || seated.has(f.pk))
      out.push({ node: f.node, x: f.x, y: f.y, depth: f.depth, r: f.r, shown: f.shown, face: true })
    }
    drawn.current = out

    // The middle's name under it: "You", or whose web this is (GlobeScene: the core's label, 13pt bold).
    g.font = "700 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif"; g.textAlign = "center"; g.textBaseline = "top"
    g.lineWidth = 3; g.lineJoin = "round"; g.strokeStyle = "rgb(0 0 0 / .65)"; g.strokeText(label, me.x, me.y + me.r + 5)
    g.fillStyle = "#fff"; g.fillText(label, me.x, me.y + me.r + 5)

    // A star whose card is open (a face wears its own rim).
    const p = pickedRef.current && out.find(d => d.node.pk === pickedRef.current)
    if (p && !p.face && p.depth > -0.2) {
      g.beginPath(); g.arc(p.x, p.y, 9, 0, 2 * Math.PI); g.lineWidth = 2; g.strokeStyle = "rgb(255 214 10)"; g.stroke()
    }
  }

  // A face: the profile picture once it has loaded (asked for only when the face holds a seat and is big enough to see), a
  // coloured disc until then, as Avatar draws it. Each picture is drawn once into a small round bitmap and the frames
  // draw that: a full-size photo scaled down every frame is what makes a big web slow.
  // A face: the profile picture once it has loaded (asked for only when the face holds a seat and is big enough to see),
  // until then a disc of its own colour with the first initial. The rim is tinted by kind (RIM) with a soft glow, as
  // GlobeScene draws faces. Each picture is drawn once into a small round bitmap and the frames draw that: a full-size
  // photo scaled down every frame is what makes a big web slow.
  const face = (g, pk, x, y, r, alpha, kind, load) => {
    const p = getProfile(pk), url = p?.picture
    const img = url && images.current.get(url)
    if (url && !img && load && r >= 6 && loadsLeft.current > 0) {
      loadsLeft.current--
      images.current.set(url, "loading")
      const im = new Image()
      im.decoding = "async"; im.referrerPolicy = "no-referrer"
      im.onload = () => { images.current.set(url, roundBitmap(im)); request() }
      im.onerror = () => images.current.set(url, "failed")
      im.src = url
    }
    g.globalAlpha = alpha
    const [rr, rg, rb] = kind === "me" ? [230, 115, 38] : RIM[kind] ?? RIM.follow
    g.beginPath(); g.arc(x, y, r + 1.5, 0, 2 * Math.PI)
    g.lineWidth = 4; g.strokeStyle = `rgb(${rr} ${rg} ${rb} / .22)`; g.stroke()
    if (img && typeof img === "object") g.drawImage(img, x - r, y - r, 2 * r, 2 * r)
    else {
      g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI); g.fillStyle = `hsl(${hueOf(pk)} 29% 48%)`; g.fill()
      const initial = Array.from(p?.name?.trim() ?? "")[0]?.toUpperCase()
      if (initial && r >= 7) {
        g.font = `700 ${Math.round(r)}px -apple-system, BlinkMacSystemFont, system-ui, sans-serif`; g.textAlign = "center"; g.textBaseline = "middle"
        g.fillStyle = "rgb(255 255 255 / .92)"; g.fillText(initial, x, y + 0.5)
      }
    }
    g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI)
    g.lineWidth = Math.max(1.2, r * 0.12); g.strokeStyle = `rgb(${rr} ${rg} ${rb})`; g.stroke()
    g.globalAlpha = 1
  }

  // One frame at a time, and only while the globe moves or a face is still fading.
  const request = () => { if (!frame.current) frame.current = requestAnimationFrame(tick) }
  const tick = t => {
    frame.current = 0
    const dt = last.current ? Math.min(0.05, (t - last.current) / 1000) : 1 / 60
    if (moving(cam.current)) cam.current = step(cam.current, dt, reducedMotion())
    draw(dt)
    if (moving(cam.current) || fading.current) { last.current = t; request() } else last.current = 0
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
  useEffect(request, [nodes, picked, layer, path, lit])
  useEffect(() => {
    if (!centre) return
    cam.current = centre === web.me ? home(cam.current) : flyTo(cam.current, facing(direction(centre)))
    request()
    onCentred()
  }, [centre])

  // Gestures: one finger or the mouse spins (a flick carries on), two fingers pinch, the wheel zooms, a double-click
  // goes home, a tap opens a card.
  const local = e => { const r = canvas.current.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] }
  const pinchDist = () => { const [a, b] = [...pointers.current.values()]; return Math.hypot(a[0] - b[0], a[1] - b[1]) }
  const down = e => {
    canvas.current.setPointerCapture?.(e.pointerId)
    pointers.current.set(e.pointerId, local(e))
    cam.current = { ...cam.current, spin: [0, 0, 0], target: null, dragging: true }
    const [x, y] = local(e)
    gesture.current = { startX: x, startY: y, moved: 0, samples: [[performance.now(), x, y]], pinch: pointers.current.size === 2 ? pinchDist() : null }
    request()
  }
  const move = e => {
    if (!pointers.current.has(e.pointerId) || !gesture.current) return
    const prev = pointers.current.get(e.pointerId), now = local(e)
    pointers.current.set(e.pointerId, now)
    const gs = gesture.current
    if (pointers.current.size >= 2) {
      const d = pinchDist()
      if (gs.pinch > 0) cam.current = zoomNow(cam.current, d / gs.pinch)
      gs.pinch = d; gs.moved = Infinity
    } else {
      cam.current = drag(cam.current, now[0] - prev[0], now[1] - prev[1])
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
    if (pointers.current.size) { gs.pinch = pointers.current.size === 2 ? pinchDist() : null; return }
    gesture.current = null
    cam.current = { ...cam.current, dragging: false }
    if (gs.moved < 6) {
      const [x, y] = local(e)
      const n = hit(drawn.current, x, y)
      onPick(n ? n.pk : null)
      request()
      return
    }
    // Speed over the last ~80 ms of the drag.
    const t = performance.now(), recent = gs.samples.filter(s => t - s[0] < 80)
    if (recent.length >= 2) {
      const [t0, x0, y0] = recent[0], [t1, x1, y1] = recent.at(-1)
      const dt = Math.max(0.008, (t1 - t0) / 1000)
      cam.current = flick(cam.current, (x1 - x0) / dt, (y1 - y0) / dt, reducedMotion())
    }
    request()
  }
  const wheel = e => {
    e.preventDefault()
    // A trackpad pinch arrives as a wheel with ctrlKey and small deltas; a mouse wheel as bigger ones.
    cam.current = zoomBy(cam.current, Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0018)), reducedMotion())
    request()
  }
  useEffect(() => {
    const c = canvas.current
    c.addEventListener("wheel", wheel, { passive: false }) // passive listeners can't stop the page scrolling
    return () => c.removeEventListener("wheel", wheel)
  }, [])
  const key = e => {
    const turns = { ArrowLeft: [-40, 0], ArrowRight: [40, 0], ArrowUp: [0, -40], ArrowDown: [0, 40] }
    if (turns[e.key]) cam.current = drag(cam.current, ...turns[e.key])
    else if (e.key === "+" || e.key === "=") cam.current = zoomBy(cam.current, 1.25, reducedMotion())
    else if (e.key === "-") cam.current = zoomBy(cam.current, 0.8, reducedMotion())
    else if (e.key === "0" || e.key === "Home") cam.current = home(cam.current)
    else return
    e.preventDefault(); request()
  }
  const goHome = () => { cam.current = home(cam.current); request() }

  return (
    <div class="wot-globe" ref={box}>
      <canvas ref={canvas} tabIndex={0} role="img"
        aria-label={`Globe of ${whose ? `${whose}'s` : "your"} web: ${web.follows.length} follows, ${web.extended.length} vouched, ${web.further.length} further out. Drag to spin, scroll or pinch to zoom, double-click to come back to the start.`}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onDblClick={goHome} onKeyDown={key} />
    </div>
  )
}

/** BITMAP px square, round, cover-cropped (net/face-cache.js FACE_PX). */
const BITMAP = FACE_PX
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
