// nostrvault.app/stats chart: "Posting users over time", a stacked area by platform drawn from /stats/stats-history.jsonl
// (one line per day of public totals, written by scripts/stats/history.mjs). Plain SVG, no library. Days rebuilt from
// poster records ("reconstructed": true) are drawn lighter with a dashed top line; days counted by a daily scan are solid.
// historyPoints() and chartPaths() are pure and tested by scripts/stats/test/chart.test.mjs.

export const CHART_PLATFORMS = ["Android", "iPhone", "iPad", "Mac", "Linux", "Web"]
export const CHART_COLORS = { Android: "#3ddc84", iPhone: "#0a84ff", iPad: "#64d2ff", Mac: "#bf5af2", Linux: "#ff9f0a", Web: "#ff375f" }

/**
 * The history file's text as chart points: one entry per day in date order (a repeated day keeps its last line),
 * `stacks[p][i]` = the top of platform p's band on day i (platforms stacked in CHART_PLATFORMS order), `firstScanned` =
 * the index of the first day not marked reconstructed (-1 when every day is), `max` = the highest stack top.
 * Lines that are not JSON or have no date are skipped. null when fewer than two days remain.
 */
export function historyPoints(text) {
  const byDate = new Map()
  for (const raw of String(text ?? "").split("\n")) {
    if (!raw.trim()) continue
    let line
    try { line = JSON.parse(raw) } catch { continue }
    if (!line || typeof line.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(line.date)) continue
    byDate.set(line.date, line)
  }
  const days = [...byDate.values()].sort((a, b) => (a.date < b.date ? -1 : 1))
  if (days.length < 2) return null
  const stacks = Object.fromEntries(CHART_PLATFORMS.map(p => [p, []]))
  let max = 0
  for (const day of days) {
    let top = 0
    for (const p of CHART_PLATFORMS) {
      const n = Number(day.by_platform?.[p])
      top += Number.isFinite(n) && n > 0 ? n : 0
      stacks[p].push(top)
    }
    max = Math.max(max, top)
  }
  return {
    dates: days.map(d => d.date),
    stacks,
    firstScanned: days.findIndex(d => d.reconstructed !== true),
    max,
  }
}

const r = n => Math.round(n * 10) / 10

/**
 * SVG path data for the points in a w×h box: per platform a reconstructed band and a scanned band (either "" when that
 * part has no width), the total's top line split the same way, and the x where the solid part starts (null when none).
 */
export function chartPaths(pts, { w = 600, h = 240 } = {}) {
  const n = pts.dates.length
  const x = i => r((i / (n - 1)) * w)
  const y = v => r(h - (pts.max > 0 ? (v / pts.max) * h : 0))
  const split = pts.firstScanned
  // The solid part starts at the last rebuilt day, so the step into the first scanned day is drawn solid.
  const ranges = split === -1 ? [[0, n - 1], null] : split === 0 ? [null, [0, n - 1]] : [[0, split - 1], [split - 1, n - 1]]
  const band = (upper, lower, [a, b]) => {
    if (b <= a) return ""
    const top = []
    for (let i = a; i <= b; i++) top.push(`${x(i)},${y(upper[i])}`)
    const bottom = []
    for (let i = b; i >= a; i--) bottom.push(`${x(i)},${lower ? y(lower[i]) : h}`)
    return `M${top.join("L")}L${bottom.join("L")}Z`
  }
  const line = (vals, [a, b]) => {
    if (b <= a) return ""
    const pts2 = []
    for (let i = a; i <= b; i++) pts2.push(`${x(i)},${y(vals[i])}`)
    return `M${pts2.join("L")}`
  }
  const bands = CHART_PLATFORMS.map((p, k) => {
    const lower = k === 0 ? null : pts.stacks[CHART_PLATFORMS[k - 1]]
    return {
      platform: p,
      reconstructed: ranges[0] ? band(pts.stacks[p], lower, ranges[0]) : "",
      scanned: ranges[1] ? band(pts.stacks[p], lower, ranges[1]) : "",
    }
  })
  const total = pts.stacks[CHART_PLATFORMS[CHART_PLATFORMS.length - 1]]
  return {
    bands,
    topReconstructed: ranges[0] ? line(total, ranges[0]) : "",
    topScanned: ranges[1] ? line(total, ranges[1]) : "",
    scannedX: split === -1 ? null : x(Math.max(0, split - 1)),
  }
}

const SVG = "http://www.w3.org/2000/svg"
const el = (name, attrs) => {
  const e = document.createElementNS(SVG, name)
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
  return e
}
const label = date => new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })

/** Draws the chart into #stats-chart from the history file's text; leaves the section hidden when there is nothing to draw. */
export function drawChart(text) {
  const pts = historyPoints(text)
  const section = document.getElementById("stats-chart")
  if (!pts || !section || pts.max === 0) return
  const w = 600, h = 240
  const paths = chartPaths(pts, { w, h })
  const total = pts.stacks[CHART_PLATFORMS.at(-1)]
  const svg = el("svg", { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: "none", role: "img", class: "chart-svg",
    "aria-label": `Posting users over time, ${label(pts.dates[0])} to ${label(pts.dates.at(-1))}: from ${total[0]} to ${total.at(-1)}` })
  for (const f of [0.25, 0.5, 0.75]) svg.append(el("line", { x1: 0, x2: w, y1: h * f, y2: h * f, stroke: "currentColor", "stroke-opacity": 0.12, "vector-effect": "non-scaling-stroke" }))
  for (const b of paths.bands) {
    if (b.reconstructed) svg.append(el("path", { d: b.reconstructed, fill: CHART_COLORS[b.platform], "fill-opacity": 0.35 }))
    if (b.scanned) svg.append(el("path", { d: b.scanned, fill: CHART_COLORS[b.platform], "fill-opacity": 0.9 }))
  }
  if (paths.topReconstructed) svg.append(el("path", { d: paths.topReconstructed, fill: "none", stroke: "currentColor", "stroke-width": 1.5, "stroke-dasharray": "4 4", "vector-effect": "non-scaling-stroke" }))
  if (paths.topScanned) svg.append(el("path", { d: paths.topScanned, fill: "none", stroke: "currentColor", "stroke-width": 2, "vector-effect": "non-scaling-stroke" }))
  if (paths.scannedX !== null) svg.append(el("line", { x1: paths.scannedX, x2: paths.scannedX, y1: 0, y2: h, stroke: "currentColor", "stroke-opacity": 0.5, "stroke-dasharray": "2 3", "vector-effect": "non-scaling-stroke" }))
  document.getElementById("chart-plot").append(svg)
  document.getElementById("chart-max").textContent = pts.max.toLocaleString("en-US")
  document.getElementById("chart-from").textContent = label(pts.dates[0])
  document.getElementById("chart-to").textContent = label(pts.dates.at(-1))
  const legend = document.getElementById("chart-legend")
  for (const p of CHART_PLATFORMS) {
    const li = document.createElement("li")
    const sw = document.createElement("span")
    sw.className = `swatch swatch-${p.toLowerCase()}`
    li.append(sw, document.createTextNode(p))
    legend.append(li)
  }
  const scanned = pts.firstScanned === -1 ? null : label(pts.dates[pts.firstScanned])
  document.getElementById("chart-note").textContent = scanned
    ? `Lighter, dashed: rebuilt from when we first saw each person post. Solid: counted by the daily scan, from ${scanned}.`
    : "Rebuilt from when we first saw each person post."
  section.hidden = false
}
