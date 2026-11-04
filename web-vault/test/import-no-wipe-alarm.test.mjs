// Versions a moving-in import filed must not set off the wipe alarm (Tron, PR 1637): a plain /lists read serves only
// the versions the vault filed itself, which is all readAlarms judges; Recover a List asks for the imported ones too
// (IMPORTED). Throwaway keys and a fake vault that splits its answers the way haven-go wantsImported does.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { readAlarms, alarmsIn } from "../src/net/list-wipe-alarm.js"
import { listOverview, keptVersions, IMPORTED } from "../src/net/list-versions.js"
import { importListHistory } from "../src/net/list-history-import.js"

const sk = generateSecretKey(), me = getPublicKey(sk)
const DAY = 86_400
const NOW = Math.floor(Date.now() / 1000)
const p = i => ["p", (i + 1).toString(16).padStart(64, "0")]
const follows = (n, at, client) =>
  finalizeEvent({ kind: 3, created_at: at, tags: [...Array.from({ length: n }, (_, i) => p(i)), ...(client ? [["client", client]] : [])], content: "" }, sk)

const memory = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

/** Tron's probe: 200 follows cut to 50 on purpose with Amethyst in 2025, then 10 more edits. The vault itself filed
 *  only the current version; the import found the rest. */
function probe() {
  const cutAt = NOW - 300 * DAY
  const imported = [follows(200, cutAt - DAY), follows(50, cutAt, "Amethyst")]
  for (let i = 1; i <= 10; i++) imported.push(follows(50 + i, cutAt + i * DAY))
  const own = [follows(61, NOW - DAY)]
  return { own, imported }
}

const fakeLists = ({ own, imported }, asked = []) => ({
  query: async f => {
    asked.push(f)
    const set = f["#v"]?.includes("imported") ? imported : own
    return set.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey)))
  },
})

test("Tron's 200 -> 50 probe: the alarm judges only the vault's own versions", async () => {
  globalThis.localStorage = memory()
  const data = probe()
  const ctx = { session: { pubkey: me }, vault: { lists: fakeLists(data) } }
  assert.deepEqual(await readAlarms(ctx), [])
  // Control: the same versions read together do set it off, so the split is what keeps it quiet.
  const merged = alarmsIn([...data.own, ...data.imported], me, new Set(), new Set())
  assert.equal(merged.length, 1)
  assert.equal(merged[0].how, "shrank")
  assert.equal(merged[0].from, 200)
  assert.equal(merged[0].to, 50)
})

test("Recover a List still gets the imported versions", async () => {
  const data = probe()
  const asked = []
  const ctx = { session: { pubkey: me }, vault: { lists: fakeLists(data, asked) } }
  const kept = await keptVersions(ctx.vault.lists, { kinds: [3], authors: [me] })
  assert.equal(kept.length, 13)
  assert.ok(kept.some(e => e.tags.filter(t => t[0] === "p").length === 200), "the 2025 list of 200 is offered")
  const follow = (await listOverview(ctx)).find(r => r.kind === 3)
  assert.equal(follow.versions, 13)
  assert.ok(asked.some(f => f["#v"]?.[0] === "imported") && asked.some(f => !f["#v"]), "one plain read, one imported read")
  assert.deepEqual(IMPORTED, { "#v": ["imported"] })
})

test("the import doesn't send again a version it filed before", async () => {
  const data = probe()
  const sent = []
  const lists = { ...fakeLists(data), event: async ev => { sent.push(ev); return { ok: true } } }
  const ctx = { session: { pubkey: me }, account: { relays: { read: [], write: [] } }, vault: { lists, outbox: { query: async () => [] } } }
  const all = [...data.own, ...data.imported]
  const r = await importListHistory(ctx, { relays: ["wss://h.example"], kinds: [3], ask: async () => ({ events: all, answered: true }) })
  assert.equal(r.found, 0)
  assert.equal(sent.length, 0)
})
