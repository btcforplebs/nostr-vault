// The web's first-run engine shape (net/import-jobs.js, Ted #1763's ImportJobsC): setup, then the Run-only jobs, their
// statuses and unread ranges, Run / Cancel, one at a time, and resume after a reload. Fake relays; nothing published.
import test from "node:test"
import assert from "node:assert/strict"
import { JOB_ORDER, LONG_JOBS, RUN, loadJobs, importJobsJSON, runImportJob, runAndWait, cancelImportJob, resumeImportJobs, currentLists } from "../src/net/import-jobs.js"
import { jobLine, jobButton, unreadLines, JOB_TITLE } from "../src/net/import-jobs-words.js"

const mem = () => { const m = new Map(); return { m, get length() { return m.size }, key: i => [...m.keys()][i] ?? null, getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const ME = "a".repeat(64)
const ctx = { vault: { outbox: {} }, session: { pubkey: ME }, account: { relays: { read: [], write: ["wss://a.example", "wss://b.example"] }, follows: ["f1", "f2"] } }
const T0 = Date.parse("2024-06-01T00:00:00Z") / 1000
const job = (s, name) => loadJobs(ME, s).jobs.find(j => j.name === name)

test("the file is ImportJobsC's shape: every job, in order, 'never' with its estimate, per account", () => {
  const s = mem()
  const f = JSON.parse(importJobsJSON(ME, s))
  assert.equal(f.account, ME)
  assert.equal(f.start_date, "2023-01-01")
  assert.deepEqual(f.jobs.map(j => j.name), JOB_ORDER)
  assert.deepEqual(f.jobs.map(j => [j.status, j.stored, j.unread.length]), JOB_ORDER.map(() => ["never", 0, 0]))
  assert.deepEqual(f.jobs.map(j => j.est_seconds), [11, 180, 240, 90, 45])
  assert.deepEqual(LONG_JOBS, ["replies", "older_relays", "wider_network", "list_history"])
  assert.equal(loadJobs("b".repeat(64), s).jobs[0].status, "never", "another account gets its own")
})

test("setup: a relay whose lane didn't finish makes it partial (never done) and is handed to older_relays", async () => {
  const s = mem()
  const importParts = async (v, me, relays, o) => {
    assert.deepEqual(o.phases, { lanes: true, walk: false, tagged: false })
    return { stored: 40, failed: 0, cut: ["wss://b.example"], lanes: { "wss://a.example": { how: "done", oldest: 0 }, "wss://b.example": { how: "silent", oldest: T0 } } }
  }
  const end = await runAndWait(ctx, "setup", { storage: s, deps: { importParts, currentLists: async () => 3 } })
  assert.equal(end.status, "partial")
  assert.equal(end.reason, "not_read_yet")
  assert.equal(end.stored, 43, "own notes plus current lists")
  assert.deepEqual(end.unread, [{ relay: "wss://b.example", from: "2023-01-01", to: "2024-06-01", why: "not_read_yet" }])
  const older = job(s, "older_relays")
  assert.equal(older.status, "never", "handed over, not started")
  assert.deepEqual(older.cursor, { "wss://b.example": String(T0) })
  assert.deepEqual(older.unread, [{ relay: "wss://b.example", from: "2023-01-01", to: "2024-06-01", why: "not_read_yet" }])
})

test("setup: every lane done is done; no relay at all is failed", async () => {
  const s = mem()
  const ok = await runAndWait(ctx, "setup", { storage: s, deps: { importParts: async () => ({ stored: 5, failed: 0, cut: [], lanes: { "wss://a.example": { how: "done" } } }), currentLists: async () => 0 } })
  assert.deepEqual([ok.status, ok.reason], ["done", "ok"])
  const none = await runAndWait(ctx, "setup", { storage: s, deps: { importParts: async () => { throw new Error("no relay reachable") }, currentLists: async () => 0 } })
  assert.deepEqual([none.status, none.reason], ["failed", "no_relay"])
  assert.ok(none.unread.length > 0 && none.unread.every(u => u.why === "unreachable" && u.from === "2023-01-01"), "each relay listed as unread")
})

test("replies: a silent relay is partial with its range; Run again skips relays already done only on a resume", async () => {
  const s = mem()
  let skipped
  const importParts = async (v, me, relays, o) => { skipped = [...o.taggedSkip]; return { stored: 0, failed: 0, cut: [], tagged: { stored: 7 }, taggedHow: Object.fromEntries(relays.filter(r => !o.taggedSkip.has(r)).map(r => [r, r === "wss://b.example" ? "silent" : "done"])) } }
  const first = await runAndWait(ctx, "replies", { storage: s, deps: { importParts } })
  assert.equal(first.status, "partial")
  assert.deepEqual(first.unread.map(u => [u.relay, u.why]), [["wss://b.example", "silent"]])
  assert.equal(first.cursor["wss://a.example"], "done")
  assert.ok(!("wss://b.example" in first.cursor), "the silent relay isn't done")
  await runAndWait(ctx, "replies", { storage: s, resume: true, deps: { importParts } })
  assert.ok(skipped.includes("wss://a.example") && !skipped.includes("wss://b.example"), "a resume skips what's done")
  await runAndWait(ctx, "replies", { storage: s, deps: { importParts } })
  assert.deepEqual(skipped, [], "a fresh Run starts over")
})

test("older_relays: walks each relay from where it was left, saves its place, and a relay read back to the start is done", async () => {
  const s = mem()
  await runAndWait(ctx, "setup", { storage: s, deps: { importParts: async () => ({ stored: 0, failed: 0, cut: ["wss://b.example"], lanes: { "wss://b.example": { how: "overran", oldest: T0 } } }), currentLists: async () => 0 } })
  let from
  const importParts = async (v, me, relays, o) => { from = [...o.walkFrom]; o.onWalk("wss://b.example", T0 - 864000); return { stored: 12, failed: 0, cut: [], walked: {} } }
  const end = await runAndWait(ctx, "older_relays", { storage: s, deps: { importParts } })
  assert.deepEqual(from, [["wss://b.example", T0]])
  assert.deepEqual([end.status, end.stored, end.unread.length, end.cursor], ["done", 12, 0, undefined])
})

test("Cancel stops a running job and says cancelled; one job at a time", async () => {
  const s = mem()
  const run = (c, name, res, { signal }) => new Promise(resolve => signal.addEventListener("abort", resolve))
  let ended
  const code = await runImportJob(ctx, "wider_network", { storage: s, deps: { run }, done: j => { ended = j } })
  assert.equal(code, RUN.started)
  assert.equal(job(s, "wider_network").status, "running")
  assert.equal(await runImportJob(ctx, "replies", { storage: s }), RUN.busy, "busy while one runs")
  assert.equal(cancelImportJob("replies"), 1)
  assert.equal(cancelImportJob("wider_network"), 0)
  await new Promise(r => setTimeout(r, 20))
  assert.deepEqual([ended.status, ended.reason], ["cancelled", "cancelled"])
  assert.equal(await runImportJob(ctx, "nope", { storage: s }), RUN.unknown)
  assert.equal(await runImportJob({ session: { pubkey: ME } }, "replies", { storage: s }), RUN.notReady)
})

test("a job a reload cut stays 'running' and is picked up from its cursor on the next start", async () => {
  const s = mem()
  const f = loadJobs(ME, s)
  Object.assign(f.jobs.find(j => j.name === "replies"), { status: "running", stored: 100, cursor: { "wss://a.example": "done" } })
  s.setItem(`nv-import-jobs:${ME}`, JSON.stringify(f))
  let skipped
  const importParts = async (v, me, relays, o) => { skipped = [...o.taggedSkip]; return { stored: 0, failed: 0, cut: [], tagged: { stored: 5 }, taggedHow: { "wss://b.example": "done" } } }
  const picked = await resumeImportJobs(ctx, { storage: s, deps: { importParts } })
  assert.deepEqual(picked, ["replies"])
  assert.deepEqual(skipped, ["wss://a.example"])
  const r = job(s, "replies")
  assert.deepEqual([r.status, r.stored], ["done", 105], "a resume adds to what the cut run stored")
  assert.deepEqual(await resumeImportJobs(ctx, { storage: s }), [], "nothing else starts on its own")
})

test("wider network and list history report partial when part didn't come back", async () => {
  const s = mem()
  const w = await runAndWait(ctx, "wider_network", { storage: s, deps: { followLists: async () => new Map([["f1", {}]]) } })
  assert.deepEqual([w.status, w.stored, w.reason], ["partial", 1, "lists_missing"])
  const l = await runAndWait(ctx, "list_history", { storage: s, deps: { importListHistory: async () => ({ found: 9, answered: 3, asked: 3 }) } })
  assert.deepEqual([l.status, l.stored], ["done", 9])
})

test("current lists: the newest of each kind (and each d) from the account's relays, stored", async () => {
  const stored = []
  const vault = { outbox: { event: async e => { stored.push(e); return { ok: true } } } }
  const evs = [
    { id: "1", kind: 10000, pubkey: ME, created_at: 1, tags: [] }, { id: "2", kind: 10000, pubkey: ME, created_at: 2, tags: [] },
    { id: "3", kind: 30000, pubkey: ME, created_at: 1, tags: [["d", "x"]] }, { id: "4", kind: 30000, pubkey: ME, created_at: 1, tags: [["d", "y"]] },
    { id: "5", kind: 3, pubkey: "b".repeat(64), created_at: 9, tags: [] },
  ]
  const n = await currentLists({ ...ctx, vault }, { query: async () => evs })
  assert.equal(n, 3)
  assert.deepEqual(stored.map(e => e.id).sort(), ["2", "3", "4"])
})

test("the card's words", () => {
  assert.equal(jobLine({ status: "never", est_seconds: 180 }), "Never ran. Takes about 3 min.")
  assert.equal(jobLine({ status: "never", est_seconds: 45 }), "Never ran. Takes about 45 s.")
  assert.match(jobLine({ status: "partial", stored: 1200, ended_at: 1 }, 2000), /^Partly done .*: 1,200 brought in\. Not everything answered\.$/)
  assert.equal(jobLine({ status: "running", reason: "will_resume" }), "Picks up where it stopped")
  assert.deepEqual(unreadLines({ unread: [{ relay: "wss://nostr.wine/", from: "2023-01-01", to: "2026-11-05", why: "silent" }] }), ["nostr.wine, 2023-01-01 to 2026-11-05: didn't answer"])
  assert.deepEqual([jobButton({ status: "never" }, false), jobButton({ status: "done" }, false), jobButton({ status: "running" }, true)], ["Run", "Run again", "Cancel"])
  assert.equal(JOB_TITLE.older_relays, "Older and slower relays")
})
