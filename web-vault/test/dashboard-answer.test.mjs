// One plan step 9: the Vault Dashboard as a napplet. The shell hands words, numbers and states only, worked out by the
// sections' own word functions; a row opens a page by name, a job by name, an alarm or long job only once handed out.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { dashboardAnswer, dashboardHandlers, GO, ACTIVITY_CAP } = await import("../src/napplet/dashboard-answer.js")
const { createBus } = await import("../src/napplet/bus.js")

const NOW = Date.UTC(2026, 10, 15, 12)
const H = { nowMs: NOW, start: NOW - 2 * 3600_000 - 5 * 60_000, safari: "", startDate: "2024-01-01" }
const dash = (over = {}) => ({
  counts: { contents: null, counting: true, failed: false }, media: null, storage: { usage: 5_000_000, kept: true }, followSavedAt: null, servers: 2,
  jobs: { importing: null, media: false, export: false, status: null }, history: {}, historyRelays: true, items: [], startedInMs: 420, relayCount: 6,
  syncing: false, trusted: 1234, blocked: 1, ...over,
})
const base = (over = {}) => ({ dash: dash(), method: "nip07", devices: null, alarms: [], still: null, cache: { n: 3, busy: false, done: false }, ...over })

test("status, safety, reach: the sections' own words; a fresh vault has two things to do", () => {
  const { data } = dashboardAnswer(base(), H)
  assert.equal(data.status.line, "Up 2h 5m"); assert.match(data.status.note, /no Start or Stop/)
  assert.equal(data.safety.detail, "1 of 3")
  assert.deepEqual(data.safety.rows.map(r => [r.state, r.go ?? r.button.job]), [["done", "accounts"], ["todo", "following-backup"], ["todo", "export"]])
  assert.equal(data.safety.rows[2].button.title, "Make one")
  assert.equal(data.reach[0].title, "1,234 people can reach your inbox"); assert.equal(data.reach[1].detail, "1 person blocked.")
  assert.equal(dashboardAnswer(base({ dash: dash({ syncing: true }) }), H).data.status.line, "Updating who can reach you…")
  assert.equal(dashboardAnswer(base({ method: "" }), H).data.safety.rows[0].title, "No key on this device")
})

test("contents: counting first, then groups with their breakdown; media buckets; cache words", () => {
  let c = dashboardAnswer(base(), H).data.contents
  assert.deepEqual(c.status, { counting: true, text: "Counting…" }); assert.equal(c.groups.length, 0); assert.equal(c.media.value, "—")
  assert.equal(c.cache.line, "3 follows' contact lists, kept for quick loading"); assert.equal(c.cache.can, true)
  const contents = { total: 12, byKind: new Map([[1, 10], [6, 2]]), yours: new Map([[1, 4]]) }
  const media = { count: 2, size: 2_000_000, buckets: { photos: { count: 2, size: 2_000_000 }, videos: { count: 0, size: 0 }, audio: { count: 0, size: 0 }, other: { count: 0, size: 0 } } }
  c = dashboardAnswer(base({ dash: dash({ counts: { contents, counting: false, failed: false }, media }) }), H).data.contents
  assert.equal(c.status, null)
  assert.match(c.detail, /^12 events · /)
  assert.ok(c.groups.length > 0 && c.groups.every(g => typeof g.value === "string"))
  assert.equal(c.media.value, "2"); assert.ok(c.parts.find(p => p.cls === "media").pct > 0)
  assert.equal(dashboardAnswer(base({ cache: { n: 0, busy: false, done: true } }), H).data.contents.cache.line, "Cleared. They download again when needed.")
})

test("keep it full: import progress and Skip; buttons wait while one job runs; the status line", () => {
  const k = dashboardAnswer(base({ dash: dash({ jobs: { importing: { progress: 0.4, text: "Found notes from May... (3 found)", skippable: true }, media: false, export: false, status: { text: "boom", error: true } } }) }), H).data.keep
  assert.equal(k.import.progress, 0.4); assert.equal(k.import.skippable, true); assert.equal(k.import.disabled, true)
  assert.equal(k.media.disabled, true); assert.equal(k.history.disabled, true)
  assert.deepEqual(k.status, { text: "boom", error: true })
  const idle = dashboardAnswer(base(), H).data.keep
  assert.match(idle.import.detail, /^Since Jan 2024\. Never ran\.$/); assert.equal(idle.import.progress, null); assert.equal(idle.history.on, true)
})

test("activity: health and the newest lines, capped; devices counted on the mesh; nothing that looks like a key", () => {
  const items = Array.from({ length: ACTIVITY_CAP + 20 }, (_, i) => ({ level: i === ACTIVITY_CAP + 19 ? "problem" : "good", text: `line ${i}`, at: NOW - i }))
  const { data } = dashboardAnswer(base({ dash: dash({ items }), devices: [{ id: "x", title: "Phone", state: "online", line: "On the mesh" }, { id: "y", title: "Mac", state: "offline", line: "Last seen 2d ago" }] }), H)
  assert.equal(data.activity.items.length, ACTIVITY_CAP); assert.equal(data.activity.health, "problem"); assert.equal(data.activity.pill, "Problem")
  assert.equal(data.devices.detail, "1 of 2 on the mesh"); assert.equal(data.devices.rows[0].id, undefined)
  assert.equal(dashboardAnswer(base(), H).data.devices.rows, null, "still checking")
  assert.doesNotMatch(JSON.stringify(data), /[0-9a-f]{64}|#\//)
})

test("handlers: pages by name only, jobs by name, alarms and long jobs only once handed out", async () => {
  const calls = []
  const alarm = { after: { id: "a".repeat(64), kind: 3, created_at: 1, tags: [] }, before: { id: "b".repeat(64), kind: 3, created_at: 0, tags: [] }, lost: 20, kept: 1, client: "" }
  const still = { file: { jobs: [{ name: "replies", status: "never", unread: [] }, { name: "secret", status: "never" }] }, here: null, busy: false, note: "", press: () => {} }
  const ctl = new Proxy({}, { get: (_, k) => (...a) => calls.push([k, ...a]) })
  let answer = null
  const bus = createBus(), me = { dTag: "nv-dashboard", send: () => {} }
  for (const hd of dashboardHandlers({ answer: () => answer, ctl })) bus.register({ id: "shell:nv-dashboard", title: "NV", conventions: [], ...hd })
  const ask = (action, payload = {}) => bus.invoke(me, { archetype: "dashboard", action, payload })
  assert.equal((await ask("state")).data, null, "nothing yet")
  answer = dashboardAnswer(base({ alarms: [alarm], still }), H)
  assert.equal(answer.data.wipes[0].id, alarm.after.id)
  assert.equal((await ask("keep", { id: alarm.after.id })).ok, false, "not handed out yet")
  assert.equal((await ask("state")).ok, true)
  assert.equal((await ask("go", { to: "relays" })).ok, true)
  assert.equal((await ask("go", { to: "#/settings/keys" })).ok, false)
  assert.equal((await ask("go", { to: "__proto__" })).ok, false)
  assert.equal((await ask("go", { to: `recover:${alarm.after.id}` })).ok, true)
  assert.equal((await ask("run", { job: "export" })).ok, true)
  assert.equal((await ask("run", { job: "rm" })).ok, false)
  assert.equal((await ask("history", { on: "yes" })).ok, false)
  assert.equal((await ask("history", { on: false })).ok, true)
  assert.equal((await ask("keep", { id: alarm.after.id })).ok, true)
  assert.equal((await ask("pair", { mode: "show" })).ok, true)
  assert.equal((await ask("pair", { mode: "send" })).ok, false)
  assert.equal((await ask("report", { how: "copy" })).ok, true)
  assert.deepEqual(answer.data.still.rows.map(r => [r.name, r.button]), [["replies", "Run"]])
  assert.equal((await ask("still", { name: "replies" })).ok, true)
  assert.equal((await ask("still", { name: "secret" })).ok, false, "not a long job")
  assert.deepEqual(calls.map(c => c[0]), ["go", "go", "run", "history", "keep", "pair", "report", "still"])
  assert.equal(calls[0][1], GO.relays); assert.equal(calls[1][1], "#/settings/recover-list?kind=3")
})
