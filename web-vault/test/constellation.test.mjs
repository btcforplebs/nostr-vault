// Constellation faces (components/constellation.js): the same pubkey gives the same drawing on web, Apple and Android.
// test/fixtures/CONSTELLATION_VECTORS.json is the spec's test vectors; Apple and Android check the same file.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { constellation, constellationSvg, constellationUrl, fnv1a, mulberry32, hslHex } from "../src/components/constellation.js"

const { vectors } = JSON.parse(readFileSync(new URL("./fixtures/CONSTELLATION_VECTORS.json", import.meta.url), "utf8"))
const bytes = hex => hex.match(/../g).map(x => parseInt(x, 16))

test("five vectors: seed, first draws, stars, links, the bright star, dust, clouds and colours match exactly", () => {
  assert.equal(vectors.length, 5)
  for (const v of vectors) {
    const seed = fnv1a(bytes(v.hex)), r = mulberry32(seed)
    assert.equal("0x" + seed.toString(16).padStart(8, "0"), v.seed)
    assert.deepEqual([r(), r(), r()].map(x => +x.toFixed(10)), v.firstDraws)
    const c = constellation(v.hex)
    assert.equal(c.hue, v.hue)
    assert.deepEqual(c.stars.map(s => [s.x, s.y, s.r]), v.stars)
    assert.deepEqual(c.links, v.links)
    assert.equal(c.you, v.you)
    assert.deepEqual(c.dust.map(d => [d.x, d.y, d.r]), v.dust)
    assert.deepEqual(c.clouds.map(k => [k.x, k.y, k.radius, k.color, k.alpha]), v.clouds)
    assert.deepEqual([c.sky.inner, c.sky.outer, c.line, c.star, c.glow], [...v.sky, v.line, v.star, v.glow])
  }
})

test("every face is filled: 9-13 stars inside the circle, all linked into one web, the bright star the best linked", () => {
  for (let k = 0; k < 300; k++) {
    const hex = Array.from({ length: 32 }, (_, i) => ((k * 7919 + i * 104729) % 256).toString(16).padStart(2, "0")).join("")
    const c = constellation(hex)
    assert.ok(c.stars.length >= 9 && c.stars.length <= 13, `${hex}: ${c.stars.length} stars`)
    for (const s of c.stars) assert.ok(Math.hypot(s.x - 50, s.y - 50) <= 44.01)
    const seen = new Set([0]), grow = () => { for (const [i, j] of c.links) { if (seen.has(i)) seen.add(j); if (seen.has(j)) seen.add(i) } }
    for (let n = 0; n < c.stars.length; n++) grow()
    assert.equal(seen.size, c.stars.length, "one web")
    const deg = c.stars.map((_, i) => c.links.filter(l => l.includes(i)).length)
    assert.equal(deg[c.you], Math.max(...deg), "the bright star has the most links")
  }
})

test("HSL to hex rounds each channel half up", () => {
  assert.equal(hslHex(0, 100, 50), "#ff0000")
  assert.equal(hslHex(120, 100, 25), "#008000")
  assert.equal(hslHex(269, 55, 24), vectors[0].sky[0])
})

test("the SVG draws one bright star and is cached as a data: URL per pubkey", () => {
  const hex = vectors[0].hex
  assert.equal((constellationSvg(hex).match(/r="5.2"/g) || []).length, 1)
  assert.ok(constellationUrl(hex).startsWith("data:image/svg+xml"))
  assert.equal(constellationUrl(hex), constellationUrl(hex))
})
