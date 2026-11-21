// A face for an account with no picture: a small constellation drawn from the pubkey (Logen 2026-11-21, "filled in
// more, less negative space"). Apple and Android draw the same thing from RESEARCH/NV_CONSTELLATION_AVATAR_SPEC.md,
// whose test vectors test/constellation.test.mjs checks. Change one, change all three and the vectors.
//
// Everything comes from one number stream: FNV-1a over the 32 pubkey bytes seeds mulberry32. Coordinates are in a
// 100x100 box, rounded to 2 decimals before they are used again; colours are HSL turned into whole-number RGB.

const R2 = x => Math.floor(x * 100 + 0.5) / 100

/** FNV-1a, 32 bit, over the bytes. */
export function fnv1a(bytes) {
  let h = 0x811c9dc5
  for (const b of bytes) { h ^= b; h = Math.imul(h, 0x01000193) >>> 0 }
  return h >>> 0
}

/** mulberry32: -> next() in [0, 1). */
export function mulberry32(seed) {
  let s = seed >>> 0
  return () => {
    s = (s + 0x6d2b79f5) >>> 0
    let t = s
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** HSL (h 0-359, s and l 0-100) -> "#rrggbb", each channel rounded half up. */
export function hslHex(h, s, l) {
  s /= 100; l /= 100
  const k = n => (n + h / 30) % 12
  const a = s * Math.min(l, 1 - l)
  const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1))
  return "#" + [f(0), f(8), f(4)].map(x => Math.floor(x * 255 + 0.5).toString(16).padStart(2, "0")).join("")
}

const MIN_GAP = 12, SKY = 44, MAX_TRIES = 400, LINK_MAX = 30, MAX_DEGREE = 4

/** The drawing as numbers (the spec's steps 1-9). `hex`: 64 lowercase hex chars. */
export function constellation(hex) {
  const bytes = hex.match(/../g).map(x => parseInt(x, 16))
  const rnd = mulberry32(fnv1a(bytes))
  // 2. hue, 3. how many stars
  const hue = Math.floor(rnd() * 360)
  const n = 9 + Math.floor(rnd() * 5)
  // 4. stars spread over the whole sky, never closer than MIN_GAP
  const stars = []
  for (let t = 0; t < MAX_TRIES && stars.length < n; t++) {
    const a = rnd() * 2 * Math.PI, r = SKY * Math.sqrt(rnd())
    const p = { x: R2(50 + r * Math.cos(a)), y: R2(50 + r * Math.sin(a)) }
    if (stars.every(s => (s.x - p.x) ** 2 + (s.y - p.y) ** 2 >= MIN_GAP * MIN_GAP)) stars.push(p)
  }
  // 5. sizes
  for (const s of stars) s.r = R2(2.2 + Math.floor(rnd() * 4) * 0.4)
  // 6. links: the shortest tree that reaches every star, then the shortest other links under LINK_MAX
  const d2 = (i, j) => R2((stars[i].x - stars[j].x) ** 2 + (stars[i].y - stars[j].y) ** 2)
  const links = [], degree = stars.map(() => 0), tree = new Set([0])
  const add = (i, j) => { links.push(i < j ? [i, j] : [j, i]); degree[i]++; degree[j]++ }
  while (tree.size < stars.length) {
    let best = null
    for (const i of [...tree].sort((a, b) => a - b)) for (let j = 0; j < stars.length; j++) {
      if (tree.has(j)) continue
      const d = d2(i, j)
      if (!best || d < best.d) best = { i, j, d } // a tie keeps the pair found first
    }
    add(best.i, best.j); tree.add(best.j)
  }
  const linked = new Set(links.map(([i, j]) => `${i}-${j}`))
  const others = []
  for (let i = 0; i < stars.length; i++) for (let j = i + 1; j < stars.length; j++) if (!linked.has(`${i}-${j}`)) others.push({ i, j, d: d2(i, j) })
  others.sort((a, b) => a.d - b.d || a.i - b.i || a.j - b.j)
  for (const o of others) {
    if (links.length >= stars.length - 1 + Math.floor(stars.length / 2)) break
    if (o.d >= LINK_MAX * LINK_MAX || degree[o.i] >= MAX_DEGREE || degree[o.j] >= MAX_DEGREE) continue
    add(o.i, o.j)
  }
  // 7. you: the star with the most links, then the one nearest the middle, then the lowest index
  let you = 0
  const mid = i => (stars[i].x - 50) ** 2 + (stars[i].y - 50) ** 2
  for (let i = 1; i < stars.length; i++) if (degree[i] > degree[you] || (degree[i] === degree[you] && mid(i) < mid(you))) you = i
  // 8. dust: 16 draws, kept only inside the circle
  const dust = []
  for (let k = 0; k < 16; k++) {
    const x = R2(6 + rnd() * 88), y = R2(6 + rnd() * 88), r = R2(0.5 + Math.floor(rnd() * 3) * 0.25)
    if ((x - 50) ** 2 + (y - 50) ** 2 <= 48 * 48) dust.push({ x, y, r })
  }
  // 9. two nebula clouds behind everything
  const cloud = (radius, h, s, l, alpha) => {
    const a = rnd() * 2 * Math.PI, d = 10 + rnd() * 20
    return { x: R2(50 + d * Math.cos(a)), y: R2(50 + d * Math.sin(a)), radius, color: hslHex(h, s, l), alpha }
  }
  const clouds = [cloud(42, (hue + 50) % 360, 75, 50, 0.5), cloud(34, (hue + 320) % 360, 70, 45, 0.4)]
  return {
    hue, stars, links, you, dust, clouds,
    sky: { inner: hslHex(hue, 55, 24), outer: hslHex((hue + 30) % 360, 60, 8) },
    line: hslHex(hue, 85, 84), star: hslHex(hue, 60, 96), glow: hslHex(hue, 90, 85),
  }
}

/** The drawing as SVG, `size` px square (the box is 100 units). Draw order: sky, clouds, dust, links, glow, stars. */
export function constellationSvg(hex, size = 100) {
  const c = constellation(hex), id = "nvc" + hex.slice(0, 12)
  const you = c.stars[c.you]
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">` +
    `<defs><radialGradient id="${id}s" cx="38" cy="32" r="78" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${c.sky.inner}"/><stop offset="1" stop-color="${c.sky.outer}"/></radialGradient>` +
    c.clouds.map((k, i) => `<radialGradient id="${id}c${i}" cx="${k.x}" cy="${k.y}" r="${k.radius}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${k.color}" stop-opacity="${k.alpha}"/><stop offset="1" stop-color="${k.color}" stop-opacity="0"/></radialGradient>`).join("") +
    `<radialGradient id="${id}g" cx="${you.x}" cy="${you.y}" r="14" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${c.glow}" stop-opacity="0.9"/><stop offset="1" stop-color="${c.glow}" stop-opacity="0"/></radialGradient>` +
    `<clipPath id="${id}k"><circle cx="50" cy="50" r="50"/></clipPath></defs>` +
    `<g clip-path="url(#${id}k)"><rect width="100" height="100" fill="url(#${id}s)"/>` +
    c.clouds.map((_, i) => `<rect width="100" height="100" fill="url(#${id}c${i})"/>`).join("") +
    c.dust.map(d => `<circle cx="${d.x}" cy="${d.y}" r="${d.r}" fill="#ffffff" fill-opacity="0.45"/>`).join("") +
    c.links.map(([i, j]) => `<line x1="${c.stars[i].x}" y1="${c.stars[i].y}" x2="${c.stars[j].x}" y2="${c.stars[j].y}" stroke="${c.line}" stroke-opacity="0.55" stroke-width="2.2" stroke-linecap="round"/>`).join("") +
    `<circle cx="${you.x}" cy="${you.y}" r="14" fill="url(#${id}g)"/>` +
    c.stars.map((s, i) => `<circle cx="${s.x}" cy="${s.y}" r="${i === c.you ? 5.2 : s.r}" fill="${c.star}"/>`).join("") +
    `</g></svg>`
}

/** A data: URL of the drawing, made once per pubkey (an <img> is one element; the SVG would be ~50). */
const urls = new Map()
export function constellationUrl(hex) {
  let u = urls.get(hex)
  if (!u) {
    u = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(constellationSvg(hex))
    if (urls.size >= 2000) urls.delete(urls.keys().next().value)
    urls.set(hex, u)
  }
  return u
}
