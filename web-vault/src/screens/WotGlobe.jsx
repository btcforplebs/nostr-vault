// The Web of Trust globe, as the iPhone's: you in the middle, your follows' faces on the sphere round you, the
// extended network on the next shell out and everyone further out on a faint outer one, the most linked of them as
// faces too. Drag to spin it (a flick
// carries on), pinch or the wheel to zoom, double-click to come back to the start; tap a face for its trust card.
// Faces fade and shrink rolling toward the rim and round the back, and give up their seat to a nearer face instead of
// piling up. Only what's on screen is drawn, and nothing is drawn while the globe is still. The maths is
// net/wot-globe.js.
import { useEffect, useRef } from "preact/hooks"
import { getProfile, onProfiles } from "../net/profiles.js"
import { FURTHER_CAP } from "../net/wot.js"
import {
  RADIUS, newCamera, moving, drag, flick, zoomBy, zoomNow, flyTo, facing, direction, home, step, projector, outline,
  faceShown, faceRadius, dotLight, seatFade, faceSize, seats, onScreen, hit, OUTER_ALPHA,
} from "../net/wot-globe.js"

const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
const DOT_COLOUR = { extended: [51, 204, 153, 0.75], further: [255, 255, 255, 0.28] }
const EMBER = [230, 115, 38, 0.7]

export function WotGlobe({ web, nodes, picked, onPick, centre, onCentred, capped }) {
  const box = useRef(null), canvas = useRef(null)
  const cam = useRef(newCamera())
  const size = useRef({ w: 0, h: 0 })
  const drawn = useRef([])
  const fades = useRef(new Map()) // follow pk -> seat fade 0..1
  const fading = useRef(false)
  const frame = useRef(0), last = useRef(0)
  const images = useRef(new Map()) // picture url -> a small round bitmap of it | "loading" | "failed"
  const pointers = useRef(new Map())
  const gesture = useRef(null)
  const pickedRef = useRef(picked)
  pickedRef.current = picked

  const draw = dt => {
    const c = canvas.current
    if (!c) return
    const { w, h } = size.current
    const dpr = globalThis.devicePixelRatio || 1
    const g = c.getContext("2d")
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, w, h)
    const k = cam.current, project = projector(k, w, h), reduce = reducedMotion()
    const mx = w / 2, my = h / 2

    // The shells' outlines: a faint ring round your follows, a fainter one round the extended network.
    g.lineWidth = 0.8
    for (const [r, a] of [[RADIUS.follow, 0.14], [RADIUS.extended, 0.07]]) {
      const o = outline(r, k, w, h)
      if (o < Math.hypot(w, h)) { g.beginPath(); g.arc(mx, my, o, 0, 2 * Math.PI); g.strokeStyle = `rgb(184 209 255 / ${a})`; g.stroke() }
    }

    // Project everyone once; dots go into a few brightness bands per layer, so a big web is a handful of fills.
    const out = [], faces = []
    const bands = { extended: [[], [], [], []], further: [[], [], [], []] }
    for (const node of nodes) {
      if (node.layer === "me") continue
      const p = project(node.p)
      if (!p || !onScreen(p.x, p.y, w, h)) continue
      if (node.face) {
        const lead = node.layer === "follow"
        faces.push({ pk: node.pk, node, x: p.x, y: p.y, depth: p.depth, r: faceSize(lead ? "follow" : "outer", p, k.zoom), lead, alpha: lead ? 1 : OUTER_ALPHA })
        continue
      }
      const light = dotLight(p.depth)
      bands[node.layer][Math.min(3, Math.floor((light - 0.35) / 0.65 * 4))].push(p)
      out.push({ node, x: p.x, y: p.y, depth: p.depth, face: false })
    }
    for (const layer of ["further", "extended"]) {
      const [r, gr, b, a] = DOT_COLOUR[layer]
      bands[layer].forEach((list, i) => {
        if (!list.length) return
        g.beginPath()
        for (const p of list) { const s = (layer === "extended" ? 2.6 : 1.7) * p.scale * Math.min(k.zoom, 1.8); g.moveTo(p.x + s, p.y); g.arc(p.x, p.y, s, 0, 2 * Math.PI) }
        g.fillStyle = `rgb(${r} ${gr} ${b} / ${a * (0.35 + 0.65 * (i + 0.5) / 4)})`; g.fill()
      })
    }

    // Seats: who shows a face this frame, each fading in or out over a quarter second. You hold the middle seat, so a
    // face rolling across you fades rather than covering you.
    const meP = project([0, 0, 0])
    const me = { pk: web.me, node: nodes[0], x: meP.x, y: meP.y, depth: Infinity, r: faceSize("me", meP, k.zoom), lead: true, alpha: 1, shown: 1, me: true }
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

    // Threads from you to the faces showing in front: one faint stroke.
    g.beginPath()
    for (const f of faces) if (f.lead && f.shown > 0.5 && f.depth > 0) { g.moveTo(me.x, me.y); g.lineTo(f.x, f.y) }
    g.lineWidth = 0.6; g.strokeStyle = "rgb(230 115 38 / .14)"; g.stroke()

    for (const f of all) {
      // A face losing its seat or rolling round the back fades into a small ember where it sits.
      if (!f.me && f.shown < 1) {
        const [r, gr, b, a] = EMBER
        g.beginPath(); g.arc(f.x, f.y, 2.2 * f.r / 11, 0, 2 * Math.PI)
        g.fillStyle = `rgb(${r} ${gr} ${b} / ${a * dotLight(f.depth) * (1 - f.shown)})`; g.fill()
      }
      if (f.shown > 0.01) face(g, f.pk, f.x, f.y, f.me ? f.r : faceRadius(f.r, f.shown), f.shown * f.alpha, !!f.me)
      out.push({ node: f.node, x: f.x, y: f.y, depth: f.depth, r: f.r, shown: f.shown, face: true })
    }
    drawn.current = out

    // The person whose card is open.
    const p = pickedRef.current && out.find(d => d.node.pk === pickedRef.current)
    if (p && (p.face ? p.shown > 0.3 : p.depth > -0.2)) {
      const r = p.face ? p.r : 6
      g.beginPath(); g.arc(p.x, p.y, r + 3, 0, 2 * Math.PI); g.lineWidth = 2; g.strokeStyle = "#fa9447"; g.stroke()
    }
  }

  // A face: the profile picture once it has loaded (asked for only when the face shows and is big enough to see), a
  // coloured disc until then, as Avatar draws it. Each picture is drawn once into a small round bitmap and the frames
  // draw that: a full-size photo scaled down every frame is what makes a big web slow.
  const face = (g, pk, x, y, r, alpha, ring) => {
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
    g.globalAlpha = alpha
    if (img && typeof img === "object") g.drawImage(img, x - r, y - r, 2 * r, 2 * r)
    else { g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI); g.fillStyle = `hsl(${parseInt(pk.slice(0, 6), 16) % 360} 45% 35%)`; g.fill() }
    g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI)
    g.lineWidth = ring ? 2.5 : 1; g.strokeStyle = ring ? "#e67326" : "rgb(0 0 0 / .6)"; g.stroke()
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
  useEffect(request, [nodes, picked])
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
        aria-label={`Globe of your web: ${web.follows.length} follows, ${web.extended.length} in your extended network, ${web.further.length} further out. Drag to spin, scroll or pinch to zoom, double-click to come back to the start.`}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onDblClick={goHome} onKeyDown={key} />
      <div class="wot-legend" aria-hidden="true">
        <span><i class="dot follow" />{web.follows.length} follows</span>
        <span><i class="dot extended" />{web.extended.length} extended</span>
        <span><i class="dot further" />{web.further.length} further out</span>
        {capped && <span>Up to {FURTHER_CAP.toLocaleString()} of each drawn; My Web lists all</span>}
      </div>
      <button type="button" class="small wot-home" onClick={goHome} aria-label="Back to the start">Me</button>
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
