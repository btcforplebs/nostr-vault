// A made-up desktop Vault rank copy (the engine's wot_rank_<account>.json, docs/MESH_COPY_V2_CONTRACT.md §6.5) for
// tests and headless globe checks: made-up keys, a `via` chain from each far ring in to `hop2` people and from them to
// your `follows`, and a haze for rings 3 and 4 when asked. Nothing here is anyone's real web.
//   node tools/rank-fixture.mjs <account hex> [follow hex,…] [--no-haze] > copy.json
import { pathToFileURL } from "node:url"

/** A fixed made-up key per (tag, i). */
export function fakeKey(tag, i) {
  let h = 2166136261, out = ""
  for (const c of `${tag}:${i}`) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0
  for (let k = 0; out.length < 64; k++) { h = Math.imul(h ^ (k * 40503 + 7), 16777619) >>> 0; h = (h ^ (h >>> 13)) >>> 0; out += h.toString(16).padStart(8, "0") }
  return out.slice(0, 64)
}

/**
 * -> the file as an object. `counts`: how many people each far ring's top has (at most 300), `haze`: how many haze rows
 * ring 3 and ring 4 carry (at most 700 and 1,700; 0 for none). Scores fall best first.
 */
export function rankFixture({ account, follows = [], hop2 = 40, counts = { 3: 300, 4: 300, 5: 120 }, haze = { 3: 700, 4: 1700 }, builtAt = 1795600000 }) {
  const ones = follows.length ? follows : Array.from({ length: 20 }, (_, i) => fakeKey("f", i))
  const twos = Array.from({ length: hop2 }, (_, i) => fakeKey("h2", i))
  const people = [...ones.map(pk => [pk, 100, 1]), ...twos.map((pk, i) => [pk, 90 - i / 10, 2])]
  const globe = [], rings = { 2: twos }
  for (const hop of [3, 4, 5]) {
    const keys = Array.from({ length: counts[hop] ?? 0 }, (_, i) => fakeKey(`h${hop}`, i))
    const inner = rings[hop - 1]
    keys.forEach((pk, i) => globe.push([pk, Math.max(1, 80 - hop * 5 - i / 10), hop, inner[i % inner.length]]))
    rings[hop] = keys
  }
  // The chain links one ring in: hop-2 rows, each with its follow.
  twos.forEach((pk, i) => globe.push([pk, 90 - i / 10, 2, ones[i % ones.length]]))
  const out = { account, builtAt, version: 2, maxHop: 5, params: { maxHop: 2 }, people, viewBar: 55, floor: 45, globe }
  const hz = {}
  for (const hop of [3, 4]) if (haze[hop] > 0) hz[hop] = Array.from({ length: haze[hop] }, (_, i) => [fakeKey(`z${hop}`, i), Math.max(0.5, 40 - i / 50)])
  if (Object.keys(hz).length) out.haze = hz
  return out
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const [account, follows, ...flags] = process.argv.slice(2)
  if (!/^[0-9a-f]{64}$/.test(account ?? "")) { console.error("usage: node tools/rank-fixture.mjs <account hex> [follows,…] [--no-haze]"); process.exit(2) }
  const haze = flags.includes("--no-haze") ? { 3: 0, 4: 0 } : undefined
  process.stdout.write(JSON.stringify(rankFixture({ account, follows: follows ? follows.split(",").filter(Boolean) : [], ...(haze ? { haze } : {}) })))
}
