// My devices (src/desktop/space/my-devices.js): the same status rule as the iPad's MyDevicesStatus.swift, against the
// same fixtures, plus the web's device list (mesh vaults from the 10063, then paired vaults) and loading.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { npubEncode } from "nostr-tools/nip19"
import { deviceStatus, statusLine, deviceList, loadMyDevices, ADVERT_D, SKEW, FALLBACK_TTL, ADVERT_KIND, FINDER_RELAYS } from "../src/desktop/space/my-devices.js"

const fx = JSON.parse(readFileSync(new URL("../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MyDevices/status-cases.json", import.meta.url), "utf8"))

test("the rule's constants are the fixtures'", () => {
  assert.equal(fx.rule.d, ADVERT_D)
  assert.equal(fx.rule.skew, SKEW)
  assert.equal(fx.rule.fallback_ttl, FALLBACK_TTL)
  assert.ok(fx.cases.length > 10)
})

for (const c of fx.cases) {
  test(`status: ${c.name}`, () => {
    const s = deviceStatus(c.adverts, fx.now, { connected: c.connected, checked: c.checked })
    assert.deepEqual({ state: s.state, last_seen: s.lastSeen }, c.expect)
  })
}

test("lines read as on the iPad", () => {
  const now = 1_000_000
  assert.equal(statusLine({ state: "connected", lastSeen: now }, now), "Connected now · sharing your posts and media")
  assert.equal(statusLine({ state: "online", lastSeen: now - 720 }, now), "On the mesh · sharing your posts and media")
  assert.equal(statusLine({ state: "offline", lastSeen: now - 3 * 86_400 }, now), "Offline · last shared 3 d ago")
  assert.equal(statusLine({ state: "unknown", lastSeen: null }, now), "Not seen on the mesh lately")
  assert.equal(statusLine({ state: "unchecked", lastSeen: null }, now), "Couldn't check the mesh")
})

const A = "a".repeat(64), B = "b".repeat(64)
const list = (...hexes) => ({ kind: 10063, tags: hexes.map(h => ["server", `fipsmesh://${npubEncode(h)}/`]).concat([["server", "https://blossom.example/"]]) })

test("devices: mesh vaults from the 10063 first, then paired vaults, each once", () => {
  const d = deviceList(list(A), new Set([B, A]))
  assert.deepEqual(d.map(x => [x.hex, x.role]), [[A, "Mesh vault"], [B, "Paired vault"]])
  assert.deepEqual(deviceList(undefined, undefined), [])
  assert.deepEqual(deviceList(undefined, ["not hex"]), [])
})

test("load: no devices asks no finder relay; relays failing reads as unchecked", async () => {
  const ctx = { session: { pubkey: "m".repeat(64) }, account: { relays: { read: [], write: [] } }, vault: { owners: new Set() } }
  const asked = []
  const none = await loadMyDevices(ctx, { query: async (r, f) => { asked.push(f.kinds[0]); return [] } })
  assert.deepEqual(none.devices, [])
  assert.deepEqual(asked, [10063])

  ctx.vault.owners = new Set([B])
  const failed = await loadMyDevices(ctx, { query: async (r, f) => { if (f.kinds[0] === ADVERT_KIND) throw new Error("down"); return [] } })
  assert.equal(failed.checked, false)

  const ad = { kind: ADVERT_KIND, pubkey: B, created_at: 1, tags: [["d", ADVERT_D]] }
  const other = { kind: ADVERT_KIND, pubkey: A, created_at: 1, tags: [["d", ADVERT_D]] }
  let relays
  const ok = await loadMyDevices(ctx, { query: async (r, f) => { if (f.kinds[0] === ADVERT_KIND) { relays = r; return [ad, other] } return [] } })
  assert.equal(ok.checked, true)
  assert.deepEqual(ok.adverts.get(B), [ad])
  assert.deepEqual(relays, FINDER_RELAYS)
})
