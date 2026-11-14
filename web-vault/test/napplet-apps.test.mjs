// The Apps pane's rules (plan P3, src/napplet/catalog.js): what the catalog lists (newest manifest per publisher and
// d tag, signatures checked, blocked publishers out, unrunnable ones said why), that an app's bytes are hash-checked
// before they are kept, the installed list, updates, and that Remove takes everything the app had and nothing else.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import crypto from "node:crypto"
import { catalogEntries, catalogFilter, fetchArtifact, appStore, updateFor, removeApp, retireVersion, MAX_ARTIFACT } from "../src/napplet/catalog.js"
import { grantStore, defaultGrant } from "../src/napplet/policy.js"
import { nappletKey } from "../src/napplet/manifest.js"
import { fetchVerified } from "../src/net/blossom-uri.js"

const A = "a".repeat(64), B = "b".repeat(64)
const sha = s => crypto.createHash("sha256").update(s).digest("hex")
const H1 = "1".repeat(64), H2 = "2".repeat(64)
let n = 0
const man = ({ pubkey = A, d = "notes", x = H1, at = 100, R = ["identity"], title = "Notes", extra = [] } = {}) =>
  ({ kind: 35129, pubkey, id: (++n).toString(16).padStart(64, "0"), created_at: at, content: "", tags: [["d", d], ["x", x], ["title", title], ...R.map(r => ["R", r]), ...extra] })
const memStore = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("catalog asks relays for addressable manifests only", () => {
  assert.deepEqual(catalogFilter().kinds, [35129])
})

test("catalog: newest per (publisher, d), bad signatures and blocked publishers out, broken manifests skipped", () => {
  const old = man({ at: 1 }), now = man({ at: 2, x: H2 }), other = man({ d: "other" }), blockedOne = man({ pubkey: B, d: "x" })
  const forged = man({ d: "forged" }), broken = { ...man({ d: "broken" }), tags: [["d", "broken"]] }, note = { ...man(), kind: 1 }
  const out = catalogEntries([old, now, other, blockedOne, forged, broken, note], { verify: ev => ev !== forged, blocked: new Set([B]) })
  assert.deepEqual(out.map(e => e.manifest.dTag).sort(), ["notes", "other"])
  assert.equal(out.find(e => e.manifest.dTag === "notes").manifest.hash, H2)
})

test("catalog: one that needs a domain this shell lacks is listed, not installable, and says why", () => {
  const [e] = catalogEntries([man({ R: ["identity", "llm"] })])
  assert.equal(e.runs, false)
  assert.match(e.why, /no llm/)
})

test("catalog: only https icons", () => {
  const [a] = catalogEntries([man({ extra: [["icon", "http://x.example/i.png"]] })])
  const [b] = catalogEntries([man({ d: "b", extra: [["icon", "https://x.example/i.png"]] })])
  assert.equal(a.picture, "")
  assert.equal(b.picture, "https://x.example/i.png")
})

test("fetchArtifact: kept only when the bytes hash to the manifest's x; at most 5 MB; servers from the manifest and publisher", async () => {
  const html = "<!doctype html><p>hi</p>", ev = man({ x: sha(html), extra: [["server", "https://one.example"]] })
  const asked = []
  const fake = body => async url => { asked.push(url); return new Response(body) }
  const deps = f => ({ fetchVerified: (b, s, o) => fetchVerified(b, s, { ...o, fetch: f }), serverOrigin: s => s, authorServers: async () => ["https://two.example"], usual: [] })
  assert.equal(await fetchArtifact(ev, deps(fake(html))), html)
  assert.equal(asked[0], `https://one.example/${sha(html)}.html`)
  asked.length = 0
  await assert.rejects(fetchArtifact(ev, deps(fake("<p>something else</p>"))), /wrong file/)
  assert.deepEqual(asked, [`https://one.example/${sha(html)}.html`, `https://two.example/${sha(html)}.html`])
  const big = "x".repeat(MAX_ARTIFACT + 1)
  await assert.rejects(fetchArtifact(man({ x: sha(big), extra: [["server", "https://one.example"]] }), deps(fake(big))), /wrong file/)
})

test("installed list: per account, one row per napplet line", () => {
  const s = memStore(), mine = appStore(s, A), theirs = appStore(s, B)
  mine.put(man({ at: 1 }), 10); mine.put(man({ at: 2, x: H2 }), 20)
  assert.equal(mine.list().length, 1)
  assert.equal(theirs.list().length, 0)
})

test("update: a newer manifest with another hash; same hash or older is none", () => {
  const ins = { line: `${A}:notes`, event: man({ at: 5 }) }
  assert.equal(updateFor(ins, catalogEntries([man({ at: 4, x: H2 })])), null)
  assert.equal(updateFor(ins, catalogEntries([man({ at: 9 })])), null)
  assert.equal(updateFor(ins, catalogEntries([man({ at: 9, x: H2 })])).manifest.hash, H2)
})

test("remove: the app, every version's grant and storage, its bytes; never another napplet's (prefix or colon d tag)", async () => {
  const s = memStore(), apps = appStore(s, A), grants = grantStore(s, A)
  apps.put(man({ x: H2 })); apps.put(man({ d: "notesplus" }))
  const k1 = nappletKey({ publisher: A, dTag: "notes", hash: H1 }), k2 = nappletKey({ publisher: A, dTag: "notes", hash: H2 })
  const plus = nappletKey({ publisher: A, dTag: "notesplus", hash: H1 }), colon = nappletKey({ publisher: A, dTag: "notes:x", hash: H1 })
  for (const k of [k1, k2, plus, colon]) grants.set(k, defaultGrant({ domains: ["identity"] }))
  const cleared = [], dropped = []
  const keys = await removeApp(`${A}:notes`, { apps, grants, storage: { clear: async sc => cleared.push(sc) }, artifacts: { remove: async h => dropped.push(h) } })
  assert.deepEqual(keys.sort(), [k1, k2].sort())
  assert.deepEqual(Object.keys(grants.list()).sort(), [colon, plus].sort())
  assert.deepEqual(apps.list().map(a => a.line), [`${A}:notesplus`])
  assert.deepEqual(cleared.sort(), [`${A}:notes`, k1, k2].sort())
  assert.deepEqual(dropped.sort(), [H1, H2])
})

test("update: the old version's grant, own storage and bytes go; the shared storage stays; same hash keeps all", async () => {
  const s = memStore(), grants = grantStore(s, A)
  const k1 = nappletKey({ publisher: A, dTag: "notes", hash: H1 })
  grants.set(k1, defaultGrant({ domains: ["identity"] }))
  const cleared = [], dropped = []
  const deps = { grants, storage: { clear: async sc => cleared.push(sc) }, artifacts: { remove: async h => dropped.push(h) } }
  await retireVersion(man({ x: H1 }), H1, deps)
  assert.deepEqual([cleared, dropped, Object.keys(grants.list())], [[], [], [k1]])
  await retireVersion(man({ x: H1 }), H2, deps)
  assert.deepEqual([cleared, dropped, Object.keys(grants.list())], [[k1], [H1], []])
})

test("storage clear is one exact scope (a prefix range would wipe pub:foobar with pub:foo)", () => {
  const src = fs.readFileSync(new URL("../src/napplet/storage-idb.js", import.meta.url), "utf8")
  assert.match(src, /clear: scope => tx\("readwrite", s => s\.delete\(IDBKeyRange\.bound\(\[scope, ""\], \[scope, \[\]\]\)\)\)/)
})

test("Apps page: in the Vault menu only while the napplet switch is on; #/apps routed on phone and desktop", () => {
  const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")
  assert.match(read("src/screens/VaultPagesMenu.jsx"), /nappletsOn\(\) \|\| current === APPS_PAGE\.id/)
  assert.match(read("main.jsx"), /route === "apps" && <NappletShell/)
  assert.match(read("src/desktop/DesktopShell.jsx"), /view\.route === "apps" \? <NappletShell/)
})
