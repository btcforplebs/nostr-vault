// A 3D object (kind 33331, SNO; readers/sno.js) as Nostr Vault shows it: only where it was asked for, a quoted post or
// the thread page (and so the share link, which opens the thread), never in the feed. Lit, turning slowly; on the
// thread page a drag turns it (yaw, and pitch held within ±85°), a double click sets it back, and the arrow keys turn
// it 30° (the "Rotate" action). An object that fails DECK-0003 §1.9 is never drawn: its `alt` text and the reason
// show instead, never its raw JSON.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { readSno, geometry, CARD_MAX_FACES } from "../readers/sno.js"
import { frame, paint } from "../readers/sno-draw.js"

if (import.meta.env) import("../styles/sno.css")

const SPIN = 0.35 // radians a second: one turn in about 18 s
const PITCH = 0.42, MAX_PITCH = (85 * Math.PI) / 180, STEP = Math.PI / 6
const reduced = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches

/** The canvas. `interactive`: drag, double click and keys turn it (the thread page). */
export function SnoStage({ geo, label, interactive = false }) {
  const canvas = useRef(null)
  const view = useRef({ yaw: 0.6, pitch: PITCH, dragging: null, idleUntil: 0 })
  useEffect(() => {
    const el = canvas.current
    if (!el || !geo) return
    let raf = 0, last = 0, onScreen = true, size = 0
    const draw = () => {
      const w = el.clientWidth || 300, dpr = globalThis.devicePixelRatio || 1
      if (w !== size) { size = w; el.width = Math.round(w * dpr); el.height = Math.round(w * dpr) }
      const ctx = el.getContext("2d")
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, w, w)
      paint(ctx, frame(geo, { yaw: view.current.yaw, pitch: view.current.pitch, size: w }))
    }
    // Spins only while on screen and not being turned by hand; a page hidden stops requestAnimationFrame by itself.
    const tick = t => {
      raf = 0
      const v = view.current
      if (!v.dragging && onScreen && !reduced() && t >= v.idleUntil) v.yaw += SPIN * Math.min(0.1, (t - (last || t)) / 1000)
      last = t
      draw()
      if (onScreen && !reduced()) raf = requestAnimationFrame(tick)
    }
    const io = typeof IntersectionObserver === "function" ? new IntersectionObserver(([e]) => {
      onScreen = e.isIntersecting
      if (onScreen && !raf) { last = 0; raf = requestAnimationFrame(tick) }
    }) : null
    io?.observe(el)
    view.current.redraw = draw
    draw()
    raf = requestAnimationFrame(tick)
    return () => { cancelAnimationFrame(raf); io?.disconnect() }
  }, [geo])

  const turnBy = (dy, dp) => {
    const v = view.current
    v.yaw += dy
    v.pitch = Math.max(-MAX_PITCH, Math.min(MAX_PITCH, v.pitch + dp))
    v.redraw?.()
  }
  const handlers = interactive ? {
    onPointerDown: e => { e.currentTarget.setPointerCapture?.(e.pointerId); view.current.dragging = [e.clientX, e.clientY] },
    onPointerMove: e => {
      const d = view.current.dragging
      if (!d) return
      turnBy((e.clientX - d[0]) * 0.012, (e.clientY - d[1]) * 0.012)
      view.current.dragging = [e.clientX, e.clientY]
    },
    onPointerUp: () => { view.current.dragging = null; view.current.idleUntil = performance.now() + 2500 },
    onPointerCancel: () => { view.current.dragging = null },
    onDblClick: () => { Object.assign(view.current, { yaw: 0.6, pitch: PITCH }); view.current.redraw?.() },
    onKeyDown: e => {
      const k = { ArrowLeft: [-STEP, 0], ArrowRight: [STEP, 0], ArrowUp: [0, -STEP], ArrowDown: [0, STEP] }[e.key]
      if (!k) return
      e.preventDefault(); view.current.idleUntil = performance.now() + 4000; turnBy(...k)
    },
    tabIndex: 0,
  } : {}
  return <canvas ref={canvas} class={`sno-stage${interactive ? " interactive" : ""}`} role="img" aria-label={label}
    aria-roledescription={interactive ? "3D object. Drag or use the arrow keys to rotate" : undefined} {...handlers} />
}

/** The object's model and drawing data, read once per event. */
export function useSno(ev) {
  return useMemo(() => {
    const r = readSno(ev)
    return r.ok ? { ...r, geo: geometry(r.model) } : r
  }, [ev?.id])
}

const label = s => `3D object, ${s.name || "untitled"}, ${s.vertices} ${s.vertices === 1 ? "vertex" : "vertices"}`

/** "3D object · 40 vertices": the chip and the count under the name. */
function Meta({ s }) {
  return <div class="sno-meta"><span class="sno-chip">3D object</span>{s.ok && <span>{s.vertices.toLocaleString()} {s.vertices === 1 ? "vertex" : "vertices"}</span>}</div>
}

/** One that can't be drawn: its alt text, and why (§1.9), in a small grey line. */
function Refused({ s }) {
  return (
    <div class="sno-refused">
      {s.alt && <p>{s.alt}</p>}
      <p class="sno-why">Can't show this 3D object: {s.reason}</p>
    </div>
  )
}

/** Inside a quote card: name, chip, a turning picture. Too many faces for a card: the alt text and "Open to view". */
export function SnoCard({ event }) {
  const s = useSno(event)
  const big = s.ok && s.faces > CARD_MAX_FACES
  return (
    <div class="sno sno-card">
      {s.name && <strong class="sno-name">{s.name}</strong>}
      <Meta s={s} />
      {!s.ok ? <Refused s={s} /> : big ? <p class="sno-big">{s.alt || "A large 3D object."} Open to view.</p> : <SnoStage geo={s.geo} label={label(s)} />}
    </div>
  )
}

/** On the thread page: the big stage, turned by hand. */
export function SnoBody({ event }) {
  const s = useSno(event)
  return (
    <div class="sno sno-body">
      {s.name && <h3 class="sno-name">{s.name}</h3>}
      <Meta s={s} />
      {s.ok ? <SnoStage geo={s.geo} label={label(s)} interactive /> : <Refused s={s} />}
      {s.ok && s.alt && <p class="sno-alt">{s.alt}</p>}
    </div>
  )
}
