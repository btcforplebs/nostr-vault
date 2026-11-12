// The Web of Trust mini panel's rules (src/desktop/space/wot-mini.js): who is new in your web, what this browser keeps
// to tell, and the little globe's points.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { newInWeb, readKept, writeKept, mapped, loadingText, globePoints, turn, vouchText, NEW_FOR_S, NEW_KEPT, GLOBE_OUTER } from "../src/desktop/space/wot-mini.js"

const pk = (n, c = "a") => n.toString(16).padStart(8, "0") + c.repeat(56)
const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const ME = "e".repeat(64)

test("a first look notes everyone and calls no one new", () => {
  const { fresh, kept } = newInWeb([pk(1), pk(2)], null, 1000)
  assert.deepEqual(fresh, [])
  assert.deepEqual([...kept.known].sort(), [pk(1).slice(0, 8), pk(2).slice(0, 8)])
})

test("people not seen before are new, newest first, and stay new for a week while still vouched for", () => {
  let { kept } = newInWeb([pk(1)], null, 1000)
  let r = newInWeb([pk(1), pk(2)], kept, 2000)
  assert.deepEqual(r.fresh, [pk(2)])
  r = newInWeb([pk(1), pk(2), pk(3)], r.kept, 3000)
  assert.deepEqual(r.fresh, [pk(3), pk(2)], "the newest arrival first, the earlier one kept")
  assert.deepEqual(newInWeb([pk(1), pk(3)], r.kept, 3100).fresh, [pk(3)], "no longer vouched for: no longer new")
  assert.deepEqual(newInWeb([pk(1), pk(2), pk(3)], r.kept, 2000 + NEW_FOR_S).fresh, [pk(3)], "a week on: no longer new")
})

test("someone known is never new again, even after a missing list hid them a while", () => {
  const { kept } = newInWeb([pk(1), pk(2)], null, 1000)
  const gone = newInWeb([pk(1)], kept, 2000)
  assert.deepEqual(newInWeb([pk(1), pk(2)], gone.kept, 3000).fresh, [])
})

test("muted people are never offered and never newly noted, and they drop out of new once muted", () => {
  const muted = new Set([pk(2)])
  const first = newInWeb([pk(1), pk(2)], null, 1000, muted)
  assert.deepEqual(first.fresh, [])
  assert.deepEqual([...first.kept.known].sort(), [pk(1).slice(0, 8)], "a muted person isn't noted on a first look")
  const r = newInWeb([pk(1), pk(2)], first.kept, 2000)
  assert.deepEqual(r.fresh, [pk(2)])
  const nowMuted = newInWeb([pk(1), pk(2)], r.kept, 3000, muted)
  assert.deepEqual(nowMuted.fresh, [], "muted after arriving: no longer new")
  assert.deepEqual(newInWeb([pk(1), pk(2)], nowMuted.kept, 4000).fresh, [], "and once known they don't come back as new after an unmute")
})

test("at most NEW_KEPT newcomers are kept", () => {
  const { kept } = newInWeb([], null, 1)
  const many = Array.from({ length: NEW_KEPT + 10 }, (_, i) => pk(i + 1))
  assert.equal(newInWeb(many, kept, 2).fresh.length, NEW_KEPT)
})

test("kept per account under a key signing out wipes, and a broken value reads as a first look", () => {
  const s = store()
  const { kept } = newInWeb([pk(1)], null, 1000)
  const r = newInWeb([pk(1), pk(2)], kept, 2000)
  writeKept(ME, r.kept, s)
  assert.ok(s.m.has(`nv-wot-seen:${ME}`), "ends in :<pubkey> (haven/vault.js accountKeys)")
  const back = readKept(ME, s)
  assert.deepEqual([...back.known].sort(), [pk(1).slice(0, 8), pk(2).slice(0, 8)])
  assert.deepEqual(back.fresh, [[pk(2), 2000]])
  for (const bad of ["{", "null", '{"known":3,"fresh":[]}']) { s.m.set(`nv-wot-seen:${ME}`, bad); assert.equal(readKept(ME, s), null, bad) }
  assert.equal(readKept(ME, undefined), null)
})

test("new people are only worked out once nearly every list has come or is known not to exist", () => {
  assert.equal(mapped(0, 0), false)
  assert.equal(mapped(1054, 21), true, "2% still on their way is fine")
  assert.equal(mapped(1054, 22), false)
  assert.equal(mapped(100, 0), true)
  assert.equal(loadingText(640, 1054), "Loading your web: 640 of 1,054 follows' lists")
})

test("the panel says how far the web has loaded and hides New in your web until it is ready", () => {
  const src = readFileSync(new URL("../src/desktop/space/WotMini.jsx", import.meta.url), "utf8")
  assert.match(src, /!ready \? `\$\{loadingText\(have, follows\.length\)\}…`/)
  assert.match(src, /\{status \? <p class="wm-note">\{status\}<\/p>/, "the faces only show with no status line")
  assert.match(src, /mapped\(follows\.length, unsettledLists\(follows\)\)|const left = unsettledLists\(follows\)/)
})

test("nobody muted is offered: the offer checks the block list, and nothing is called new before the list has loaded", () => {
  const src = readFileSync(new URL("../src/desktop/space/WotMini.jsx", import.meta.url), "utf8")
  assert.match(src, /newInWeb\(web\.extended, readKept\(me\), Math\.floor\(Date\.now\(\) \/ 1000\), blocked\)/, "the offer itself skips muted people")
  assert.match(src, /&& blocksLoaded/, "newcomers wait for the block list, so a late mute can't flash someone into kept")
})

test("the globe draws every follow, up to GLOBE_OUTER vouched people, and every new one", () => {
  const extended = Array.from({ length: GLOBE_OUTER + 5 }, (_, i) => pk(i + 100, "b"))
  const web = { follows: [pk(1), pk(2)], extended }
  const newOne = extended.at(-1)
  const pts = globePoints(web, [newOne])
  assert.equal(pts.filter(p => p.kind === "follow").length, 2)
  assert.equal(pts.filter(p => p.kind === "new").length, 1)
  assert.equal(pts.length, 2 + GLOBE_OUTER + 1)
  for (const { p } of pts) assert.ok(Math.hypot(...p) <= 1.31)
})

test("turning keeps a point on its shell and in the panel", () => {
  for (const a of [0, 1, 2.5]) {
    const [x, y, d] = turn([0.6, 0.48, 0.64], a, 0.38)
    assert.ok(Math.abs(Math.hypot(x, y) ** 2 + (d * 1.3) ** 2 - 1) < 1e-9)
  }
})

test("a face's title says how many of your follows vouch for them", () => {
  const web = { linkers: new Map([[pk(1), Array(12)], [pk(2), [1]]]) }
  assert.equal(vouchText(web, pk(1)), "Followed by 12 people you follow")
  assert.equal(vouchText(web, pk(2)), "Followed by 1 person you follow")
})

test("the dock draws the panels from the registry, WoT mini between Live Vault and Messages", () => {
  const src = f => readFileSync(new URL(`../src/desktop/space/${f}`, import.meta.url), "utf8")
  assert.match(src("panels.js"), /live-vault[\s\S]*wot-mini[\s\S]*messages/)
  // In the user's order (space-layout.js), over the registry's panels.
  assert.match(src("SpaceDock.jsx"), /new Map\(PANELS\.map\(p => \[p\.id, p\]\)\)/)
  assert.match(src("SpaceDock.jsx"), /shownPanels\(layout, PANEL_IDS\)[\s\S]*<Panel ctx=\{ctx\} open=\{open && !editing\} tools=\{tools\} \/>/)
  assert.match(src("WotMini.jsx"), /href=\{`#\/wot\/\$\{pk\}`\}/, "a face opens their card in the left column")
})
