// The list wipe alarm (docs/LIST_WIPE_ALARM.md): the same fixtures as iPhone/Mac and Android.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { wipeAlarm, alarmsIn, alarmLine, recordOwnList, ownListIds, dismissAlarm, dismissedAlarms, RULE, HISTORY, isProtectedKind, listName, PROTECTED_KINDS } from "../src/net/list-wipe-alarm.js"

const fx = JSON.parse(readFileSync(new URL("../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/ListAlarm/alarm-cases.json", import.meta.url)))

test("rule constants match the fixtures", () => {
  assert.deepEqual(RULE, { minItems: fx.rule.min_items, minContent: fx.rule.min_content, lookback: fx.rule.lookback, alarmMinItems: fx.rule.alarm_min_items })
  assert.equal(HISTORY, fx.rule.history)
})

for (const c of fx.cases) {
  test(`fixture: ${c.name}`, () => {
    const got = wipeAlarm(c.versions, new Set(c.own), new Set(c.dismissed))
    if (!c.expect) return assert.equal(got, null)
    assert.ok(got, "expected an alarm")
    assert.deepEqual(
      { before: got.before.id, after: got.after.id, how: got.how, from: got.from, to: got.to, lost: got.lost, client: got.client, claims_nostr_vault: got.claimsNostrVault },
      c.expect,
    )
  })
}

const memory = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

test("alarmsIn groups per list, skips other authors and own edits", () => {
  globalThis.localStorage = memory()
  const c = fx.cases.find(x => x.name === "follows emptied by another app")
  const me = "me"
  const vs = c.versions.map(v => ({ ...v, pubkey: me }))
  const stranger = vs.map(v => ({ ...v, id: v.id + "x", pubkey: "someone" }))
  assert.equal(alarmsIn([...stranger, ...vs], me, new Set(), new Set()).length, 1)
  recordOwnList({ id: vs[0].id, kind: 3 })
  recordOwnList({ id: "note", kind: 1 })
  assert.deepEqual([...ownListIds()], [vs[0].id], "only list kinds go in the own ledger")
  assert.equal(alarmsIn(vs, me).length, 0, "an own edit is quiet")
})

test("dismissed alarms stay dismissed, and the ledgers are capped", () => {
  globalThis.localStorage = memory()
  const c = fx.cases.find(x => x.name === "same-size swap")
  const vs = c.versions.map(v => ({ ...v, pubkey: "me" }))
  const [a] = alarmsIn(vs, "me")
  assert.ok(a)
  dismissAlarm(a)
  assert.equal(alarmsIn(vs, "me").length, 0)
  for (let i = 0; i < 600; i++) recordOwnList({ id: `id${i}`, kind: 3 })
  assert.equal(ownListIds().size, 500)
  assert.ok(ownListIds().has("id599") && !ownListIds().has("id0"), "keeps the newest")
  assert.ok(dismissedAlarms().has(a.after.id))
})

test("banner wording names the app, or says it didn't name itself", () => {
  const base = { after: { kind: 3, created_at: 1730000000 }, from: 40, to: 0, lost: 40 }
  assert.match(alarmLine({ ...base, how: "emptied", client: "Amethyst" }, "en-GB"), /^Your follows went from 40 to 0 on .+, changed by Amethyst\.$/)
  assert.match(alarmLine({ ...base, how: "emptied", client: null }, "en-GB"), /by an app that didn't name itself\.$/)
  assert.match(alarmLine({ ...base, how: "emptied", client: "Nostr Vault", claimsNostrVault: true }, "en-GB"),
    /changed by an app calling itself Nostr Vault\. This device didn't make that change\.$/)
  assert.match(alarmLine({ ...base, how: "swapped", to: 40, lost: 40, client: null }, "en-GB"), /lost 40 of 40 entries .+ swapped for others/)
})

test("your own emoji sets (30030) are kept and guarded like the emoji list (Apple ListShrinkRule twin)", () => {
  assert.ok(isProtectedKind(30030))
  assert.equal(listName(30030), "emoji set")
  assert.deepEqual(PROTECTED_KINDS, [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007, 10015, 10030, 10050, 10063, 30000, 30002, 30003, 30030])
})
