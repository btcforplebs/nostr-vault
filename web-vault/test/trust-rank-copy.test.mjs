// A desktop Vault's rank copy, read with the engine's own checks (net/trust-rank-copy.js), the same cases as Apple's
// TrustRankCopyTests and GlobeHazeTests. Made-up keys.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { parse, parseHaze, globePerson, HAZE_PER_RING, MAX_GLOBE_ROWS, GLOBE_PER_RING } from "../src/net/trust-rank-copy.js"
import { rankFixture } from "../tools/rank-fixture.mjs"
import { setRankCopy, rankCopyFor, onRankCopy } from "../src/net/rank-copy-store.js"

const pk = c => c.repeat(64)
const hexOf = i => i.toString(16).padStart(64, "0")
const ME = pk("a")

const file = ({ account = ME, version = 2, maxHop = 4, rows } = {}) =>
  `{"account":"${account}","builtAt":1795300000,"version":${version},"params":{},"maxHop":${maxHop},` +
  `"people":[${rows ?? `["${pk("b")}",80.5,2],["${pk("c")}",47,4]`}],"viewBar":55,"floor":45}`

test("a good copy reads every field", () => {
  const copy = parse(file(), ME)
  assert.equal(copy.builtAt, 1795300000)
  assert.equal(copy.maxHop, 4)
  assert.equal(copy.floor, 45)
  assert.equal(copy.viewBar, 55)
  assert.deepEqual(copy.people.get(pk("b")), { score: 80.5, hop: 2 })
  assert.deepEqual(copy.people.get(pk("c")), { score: 47, hop: 4 })
  assert.equal(copy.people.get(pk("d")), undefined)
  assert.deepEqual(copy.globeOrder, [], "an engine from before G1 has no globe")
  assert.equal(copy.haze.size, 0)
})

test("anything that would not pass the engine's checks is refused whole", () => {
  const cases = [
    ["another account", file({ account: pk("z") })],
    ["another version", file({ version: 3 })],
    ["maxHop past 6", file({ maxHop: 7 })],
    ["a ring past maxHop", file({ maxHop: 3 })],
    ["ring 0", file({ rows: `["${pk("b")}",50,0]` })],
    ["score over 100", file({ rows: `["${pk("b")}",100.5,2]` })],
    ["not a pubkey", file({ rows: `["../x",50,2]` })],
    ["an upper-case pubkey", file({ rows: `["${pk("B")}",50,2]` })],
    ["a short row", file({ rows: `["${pk("b")}",50]` })],
    ["a score as text", file({ rows: `["${pk("b")}","50",2]` })],
    ["a ring as a fraction", file({ rows: `["${pk("b")}",50,2.5]` })],
    ["version as text", file().replace(`"version":2`, `"version":"2"`)],
    ["maxHop as text", file().replace(`"maxHop":4`, `"maxHop":"4"`)],
    ["builtAt as text", file().replace(`"builtAt":1795300000`, `"builtAt":"1795300000"`)],
    ["a bool score", file({ rows: `["${pk("b")}",true,2]` })],
    ["not JSON", "nope"],
    ["a list", "[1]"],
  ]
  for (const [why, text] of cases) assert.equal(parse(text, ME), null, why)
})

test("a bar off the scale reads as missing", () => {
  for (const bad of ["1e300", "-1e300", "101", "-1"]) {
    const text = file().replace(`"viewBar":55,"floor":45`, `"viewBar":${bad},"floor":${bad}`)
    assert.notEqual(text, file(), bad)
    const copy = parse(text, ME)
    assert.equal(copy.viewBar, 55, bad)
    assert.equal(copy.floor, 0, bad)
  }
})

// globe: ring 3 top 1, 2; ring 4 top 3 (via 1). haze as given (GlobeHazeTests).
const hazeCopy = haze => {
  const globe = `["${hexOf(1)}",80,3,"${hexOf(9)}"],["${hexOf(2)}",70,3,"${hexOf(9)}"],["${hexOf(3)}",20,4,"${hexOf(1)}"]`
  return parse(`{"account":"${hexOf(0xa)}","builtAt":1795300000,"version":2,"maxHop":6,"people":[["${hexOf(9)}",100,1]],` +
    `"globe":[${globe}],"viewBar":55,"floor":45${haze === undefined ? "" : `,"haze":${haze}`}}`, hexOf(0xa))
}
const rows = (from, n, score = 10) => `[${Array.from({ length: n }, (_, i) => `["${hexOf(from + i)}",${score}]`).join(",")}]`

test("the globe reads in file order with each one's via", () => {
  const c = hazeCopy()
  assert.deepEqual(c.globeOrder, [hexOf(1), hexOf(2), hexOf(3)])
  assert.deepEqual(globePerson(c, hexOf(3)), { score: 20, hop: 4, via: hexOf(1) })
  assert.deepEqual(globePerson(c, hexOf(3).toUpperCase()), { score: 20, hop: 4, via: hexOf(1) })
  assert.equal(globePerson(c, hexOf(9)), null)
})

test("a bad globe refuses the copy", () => {
  const base = `{"account":"${ME}","builtAt":1,"version":2,"maxHop":5,"people":[["${pk("b")}",100,1]],"globe":`
  const bad = [
    `[["${pk("c")}",50,1,"${pk("b")}"]]`, // ring 1 is not a globe ring
    `[["${pk("c")}",50,6,"${pk("b")}"]]`, // past GlobeHop
    `[["${pk("c")}",50,3,"nope"]]`,
    `[["${pk("c")}",50,3]]`,
    `{"3":[]}`,
    `[${Array.from({ length: MAX_GLOBE_ROWS + 1 }, (_, i) => `["${hexOf(i + 1)}",1,3,"${pk("b")}"]`).join(",")}]`,
  ]
  for (const g of bad) assert.equal(parse(`${base}${g}}`, ME), null, g.slice(0, 40))
  assert.ok(parse(`${base}null}`, ME), "null is no globe")
})

test("haze decodes best first per ring", () => {
  const c = hazeCopy(`{"3":${rows(100, 3)},"4":${rows(200, 2)}}`)
  assert.deepEqual(c.haze.get(3), [hexOf(100), hexOf(101), hexOf(102)])
  assert.deepEqual(c.haze.get(4), [hexOf(200), hexOf(201)])
  assert.equal(globePerson(c, hexOf(100)), null, "haze rows are not globe rows")
  assert.equal(hazeCopy().haze.size, 0, "an engine from before H1")
})

test("a bad haze costs only the haze", () => {
  const bad = [
    `{"5":${rows(100, 1)}}`, `{"2":${rows(100, 1)}}`, `{"03":${rows(100, 1)}}`,
    `{"3":${rows(100, 1, 0)}}`, `{"3":${rows(100, 1, 101)}}`, `{"3":[["nope",10]]}`,
    `{"3":[["${hexOf(1)}",10]]}`, // already a globe row
    `{"3":${rows(100, 1)},"4":${rows(100, 1)}}`, // in two rings
    `{"3":${rows(100, HAZE_PER_RING[3] + 1)}}`,
    "[1,2]",
  ]
  for (const haze of bad) {
    const c = hazeCopy(haze)
    assert.ok(c, haze)
    assert.equal(c.haze.size, 0, haze)
    assert.equal(c.globe.size, 3, `the globe stays: ${haze}`)
    assert.equal(c.people.size, 1)
  }
  assert.equal(parseHaze({ 4: [[hexOf(100), 10]] }, 3, new Map()).size, 0, "past maxHop")
  assert.deepEqual([...parseHaze({ 4: [[hexOf(100), 10]] }, 4, new Map())], [[4, [hexOf(100)]]])
  assert.equal(hazeCopy(`{"3":${rows(100, HAZE_PER_RING[3])}}`).haze.get(3).length, 700, "a full ring is kept")
})

test("the caps are the contract's", () => {
  const contract = readFileSync(new URL("../../docs/MESH_COPY_V2_CONTRACT.md", import.meta.url), "utf8")
  const m = contract.match(/at most ([0-9,]+) and ([0-9,]+) rows/)
  assert.ok(m, "contract names the haze caps")
  assert.equal(HAZE_PER_RING[3], Number(m[1].replace(/,/g, "")))
  assert.equal(HAZE_PER_RING[4], Number(m[2].replace(/,/g, "")))
  assert.deepEqual(Object.keys(HAZE_PER_RING), ["3", "4"], "no hop-5 haze")
  assert.match(contract, new RegExp(`most ${MAX_GLOBE_ROWS.toLocaleString("en-US")} globe rows`))
  assert.match(contract, new RegExp(`top ${GLOBE_PER_RING} \\(\`GlobePerRing\`\\)`))
})

test("the test fixture is a copy the parser keeps", () => {
  const follows = [pk("1"), pk("2")]
  const c = parse(rankFixture({ account: ME, follows }), ME)
  assert.ok(c)
  assert.equal(c.haze.get(3).length, 700)
  assert.equal(c.haze.get(4).length, 1700)
  const none = parse(rankFixture({ account: ME, follows, haze: { 3: 0, 4: 0 } }), ME)
  assert.equal(none.haze.size, 0)
})

test("the store keeps a good copy, refuses a bad one, and tells listeners", () => {
  const heard = []
  const off = onRankCopy(a => heard.push(a))
  assert.equal(rankCopyFor(ME), null)
  assert.equal(setRankCopy(ME, file()), true)
  assert.equal(rankCopyFor(ME.toUpperCase()).builtAt, 1795300000)
  assert.equal(setRankCopy(ME, "nope"), false)
  assert.equal(rankCopyFor(ME).builtAt, 1795300000, "the last good copy stays")
  assert.equal(setRankCopy(ME, file({ account: pk("z") })), false, "another account's file")
  assert.equal(setRankCopy(ME, null), true)
  assert.equal(rankCopyFor(ME), null)
  off()
  setRankCopy(ME, file())
  assert.deepEqual(heard, [ME, ME])
  setRankCopy(ME, null)
  assert.equal(globalThis.__nvSetRankCopy, undefined, "no test hook outside a fixtures build")
})
