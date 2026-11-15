// The Web of Trust mini panel's globe: your follows and the people they vouch for as dots on two shells, you in the
// middle, the new people in the accent, turning slowly. It draws a few frames a second and stops while the tab is hidden;
// with reduced motion it holds still. A click opens the Web of Trust page (the big globe).
import { useEffect, useRef } from "preact/hooks"
import { RADIUS } from "../../net/wot-globe.js"
import { turn } from "./wot-mini.js"

/** One turn takes this long. */
const TURN_MS = 120_000
/** Frames a second: slow enough to cost next to nothing. */
const FPS = 12
const TILT = 0.38
const COLOR = { follow: [184, 209, 255], vouched: [158, 140, 230] }
/** On a light card the pale night-sky blues fade into white: the same hues, deeper. */
const COLOR_LIGHT = { follow: [74, 116, 204], vouched: [112, 92, 196] }
/** The accent (Settings › Appearance) and the mode, read off the page as the globe draws, so a change shows at once. */
function paint(el) {
  const css = getComputedStyle(el)
  const accent = css.getPropertyValue("--accent-rgb").trim().split(/\s+/).map(Number)
  const light = el.closest("[data-theme]")?.dataset.theme === "light"
  return { ...(light ? COLOR_LIGHT : COLOR), new: accent.length === 3 && accent.every(Number.isFinite) ? accent : [230, 115, 38] }
}
const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false

export function MiniGlobe({ points, size = 112 }) {
  const canvas = useRef(null)
  const scene = useRef(points)
  scene.current = points
  const still = useRef(null) // with reduced motion: draws the held globe again when the web fills in

  useEffect(() => {
    const c = canvas.current
    if (!c) return
    const dpr = globalThis.devicePixelRatio || 1
    c.width = size * dpr; c.height = size * dpr
    const g = c.getContext("2d")
    if (!g) return
    const half = size / 2, scale = (half - 4) / RADIUS.extended // the outer shell fills the canvas
    const draw = angle => {
      g.setTransform(dpr, 0, 0, dpr, 0, 0)
      g.clearRect(0, 0, size, size)
      const colour = paint(c)
      g.strokeStyle = `rgb(${colour.new.join(" ")} / .18)`
      g.beginPath(); g.arc(half, half, scale * RADIUS.extended, 0, Math.PI * 2); g.stroke()
      const drawn = scene.current.map(pt => ({ kind: pt.kind, at: turn(pt.p, angle, TILT) })).sort((a, b) => a.at[2] - b.at[2])
      for (const { kind, at: [x, y, depth] } of drawn) {
        const light = 0.25 + 0.75 * Math.max(0, Math.min(1, (depth + 0.6) / 1.4))
        const r = kind === "new" ? 2.6 : kind === "follow" ? 1.5 : 1.1
        g.fillStyle = `rgb(${colour[kind].join(" ")} / ${kind === "new" ? Math.max(0.5, light) : light * 0.85})`
        g.beginPath(); g.arc(half + x * scale, half + y * scale, r, 0, Math.PI * 2); g.fill()
      }
      g.fillStyle = `rgb(${colour.new.join(" ")})`
      g.beginPath(); g.arc(half, half, 4.5, 0, Math.PI * 2); g.fill()
    }
    const start = performance.now()
    const angleAt = t => ((t - start) / TURN_MS) * Math.PI * 2
    draw(0)
    if (reducedMotion()) { still.current = () => draw(0); return () => { still.current = null } }
    let frame = 0, last = 0
    const tick = t => {
      frame = requestAnimationFrame(tick)
      if (document.hidden || t - last < 1000 / FPS) return
      last = t
      draw(angleAt(t))
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [size])

  useEffect(() => { still.current?.() }, [points])

  return <canvas ref={canvas} class="wm-globe" style={{ width: size, height: size }} aria-hidden="true" />
}
