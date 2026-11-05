// First run and the Vault's "Still to bring in", on the web (Logen 2026-11-05, PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md;
// the engine's shape is haven-go/import_jobs.go, Ted #1763). `setup` is the way in: your own notes (NIP-77, then each
// relay paged), your follow list and current lists; the relays it couldn't finish are handed to older_relays. The long
// items run only when the user taps Run: replies (notes that tag you), older_relays (the 10-day walk, from where each
// relay was left), wider_network (your follows' contact lists, for the globe and Popular) and list_history (old versions
// of your lists). One at a time, across tabs (import-lock.js). A run cut by a reload or a closed tab stays "running"
// and is picked up the next time the vault starts (resumeImportJobs). Kept per account in this browser, in the same
// JSON as ImportJobsC: { account, start_date, jobs: [{ name, status, started_at, ended_at, reason, stored, unread:
// [{ relay, from, to, why }], est_seconds, cursor? }] }. Nothing says "done" if a relay didn't answer.
import { withImportLock } from "./import-lock.js"
import { importParts, IMPORT_START_DATE, storeAll } from "./sync.js"
import { ownPostRelays } from "./own-relays.js"
import { pool, uniq, DEFAULT_RELAYS, PROFILE_RELAYS } from "./pool.js"

export const JOB_ORDER = ["setup", "replies", "older_relays", "wider_network", "list_history"]
/** What the Vault card lists: the long items (setup is the way in). */
export const LONG_JOBS = ["replies", "older_relays", "wider_network", "list_history"]
export const JOB_ESTIMATES = { setup: 11, replies: 180, older_relays: 240, wider_network: 90, list_history: 45 }
export const RUN = { started: 0, unknown: 1, busy: 2, notReady: 3 }
/** How long setup's lanes may take before a relay is left to older_relays: the user waits for setup. */
export const SETUP_LANE_MS = 60_000
const CHECKPOINT_MS = 2000
const VERSION = 1
// Current lists setup brings in with the follow list (the engine's importCurrentLists): mutes, relays, media servers, …
export const CURRENT_LIST_KINDS = [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007, 10015, 10030, 10050, 10063, 30000, 30002, 30003]

const KEY = "nv-import-jobs" // per account ("<key>:<pubkey>"), so sign-out (haven/vault.js accountKeys) forgets it
const day = t => new Date(t * 1000).toISOString().slice(0, 10)
const nowSec = () => Math.floor(Date.now() / 1000)
const blank = name => ({ name, status: "never", stored: 0, unread: [], est_seconds: JOB_ESTIMATES[name] })

/** The jobs file for `me`: every job, in JOB_ORDER, "never" when it hasn't run. */
export function loadJobs(me, storage = globalThis.localStorage) {
  let f = null
  try { f = JSON.parse(storage?.getItem(`${KEY}:${me}`) ?? "null") } catch {}
  const ok = f && f.version === VERSION && f.account === me && Array.isArray(f.jobs)
  const jobs = JOB_ORDER.map(name => ({ ...blank(name), ...(ok ? f.jobs.find(j => j?.name === name) : null), name, est_seconds: JOB_ESTIMATES[name] }))
  return { version: VERSION, account: me, start_date: ok && f.start_date ? f.start_date : IMPORT_START_DATE, jobs }
}
function saveJobs(f, storage = globalThis.localStorage) {
  try { storage?.setItem(`${KEY}:${f.account}`, JSON.stringify(f)) } catch {}
  for (const cb of listeners) cb(f)
}
function updateJob(me, name, fn, storage) {
  const f = loadJobs(me, storage)
  fn(f.jobs.find(j => j.name === name), f)
  saveJobs(f, storage)
  return f
}

/** ImportJobsC's JSON for `me`. */
export const importJobsJSON = (me, storage) => JSON.stringify(loadJobs(me, storage))

const listeners = new Set()
/** Called with the file whenever a job changes, in this tab or another. -> unsubscribe */
export function onImportJobs(cb) {
  listeners.add(cb)
  const fromOtherTab = e => { if (e.key?.startsWith(`${KEY}:`)) cb(null) }
  globalThis.addEventListener?.("storage", fromOtherTab)
  return () => { listeners.delete(cb); globalThis.removeEventListener?.("storage", fromOtherTab) }
}

// This tab's running job: { name, controller }.
let running = null
export const runningJob = () => running?.name ?? null

/** The reasons a result gives, as the engine joins them: each unread range's why, then the rest, once each. */
const reasons = r => uniq([...r.unread.map(u => u.why), ...(r.partial ?? [])])

/**
 * Starts `name` for ctx's account. -> RUN code: started, unknown, busy (a job runs here or in another tab, or another
 * import holds the lock) or notReady (no vault yet). `resume`: picking a cut run up from its cursor. `done` (when
 * given) settles with the job's final state. `deps` are for tests.
 */
export async function runImportJob(ctx, name, { resume = false, storage = globalThis.localStorage, deps = {}, done } = {}) {
  if (!JOB_ORDER.includes(name)) return RUN.unknown
  if (!ctx?.vault || !ctx.session?.pubkey) return RUN.notReady
  if (running) return RUN.busy
  const me = ctx.session.pubkey
  const controller = new AbortController()
  running = { name, controller }
  let started
  const begun = new Promise(r => { started = r })
  withImportLock(async () => {
    started(RUN.started)
    let st
    updateJob(me, name, j => {
      if (!resume && name === "replies") delete j.cursor
      Object.assign(j, { status: "running", started_at: nowSec(), ended_at: undefined, reason: "" })
      st = { ...j, cursor: { ...(j.cursor ?? {}) } }
    }, storage)
    const res = { stored: 0, unread: [], partial: [], cursor: st.cursor, failReason: "", after: [] }
    let last = 0
    res.checkpoint = () => {
      if (Date.now() - last < CHECKPOINT_MS) return
      last = Date.now()
      updateJob(me, name, j => { if (j.status === "running") j.cursor = { ...res.cursor } }, storage)
    }
    try { await (deps.run ?? runJob)(ctx, name, res, { signal: controller.signal, storage, deps, startDate: loadJobs(me, storage).start_date }) }
    catch (e) { res.failReason ||= String(e?.message ?? e) === "no relay reachable" ? "no_relay" : "error" }
    const userCancel = controller.signal.aborted
    const f = updateJob(me, name, (j, file) => {
      j.cursor = Object.keys(res.cursor).length ? { ...res.cursor } : undefined
      if (userCancel) Object.assign(j, { status: "cancelled", reason: "cancelled" })
      else if (res.failReason) Object.assign(j, { status: "failed", reason: res.failReason })
      else if (res.unread.length || res.partial.length) Object.assign(j, { status: "partial", reason: reasons(res).join(",") })
      else Object.assign(j, { status: "done", reason: "ok" })
      j.stored = resume ? (j.stored ?? 0) + res.stored : res.stored
      j.unread = res.unread
      j.ended_at = nowSec()
      for (const fn of res.after) fn(file)
    }, storage)
    running = null
    return f.jobs.find(j => j.name === name)
  }).then(final => done?.(final), () => { running = null; started(RUN.busy) }) // `done` once the lock is let go
  return begun
}

/** Cancel `name` if it runs in this tab: 0 cancelling, 1 not running. */
export function cancelImportJob(name) {
  if (running?.name !== name) return 1
  running.controller.abort()
  return 0
}

/** Runs `name` and resolves with its final job state (setup during first run). */
export function runAndWait(ctx, name, opts = {}) {
  return new Promise(resolve => {
    runImportJob(ctx, name, { ...opts, done: resolve }).then(code => { if (code !== RUN.started) resolve({ name, status: "failed", reason: code === RUN.busy ? "busy" : "not_ready" }) })
  })
}

/** On every vault start: each job a reload or a closed tab left "running" is picked up from its cursor, setup first,
 *  one after another. Nothing that wasn't asked for starts. A job another tab is running holds the lock: left alone. */
export async function resumeImportJobs(ctx, { storage = globalThis.localStorage, deps = {} } = {}) {
  const me = ctx?.session?.pubkey
  if (!me) return []
  const cut = loadJobs(me, storage).jobs.filter(j => j.status === "running" && runningJob() !== j.name).map(j => j.name)
  for (const name of cut) updateJob(me, name, j => { j.reason = "will_resume" }, storage)
  const picked = []
  for (const name of cut) {
    const end = await runAndWait(ctx, name, { resume: true, storage, deps })
    if (end.reason === "busy") break // another tab has the lock: it's running there
    picked.push(name)
  }
  return picked
}

// ---- the jobs ----

async function runJob(ctx, name, res, opts) {
  const fn = { setup: runSetup, replies: runReplies, older_relays: runOlderRelays, wider_network: runWiderNetwork, list_history: runListHistory }[name]
  await fn(ctx, res, opts)
}

/** importParts, but a run that reached no relay at all lists each one as unread for the whole range (the engine's
 *  checkSeeds): failed, and never silently empty. */
async function partsOrUnreachable(parts, ctx, relays, opts, res) {
  try { return await parts(ctx.vault, ctx.session.pubkey, relays, opts) } catch (e) {
    if (String(e?.message) === "no relay reachable") for (const relay of relays) res.unread.push({ relay, from: opts.startDate, to: day(nowSec()), why: "unreachable" })
    throw e
  }
}

const lanesWhy = how => (how === "silent" ? "silent" : how === "overran" ? "slow" : how === "cut" ? "cut" : "stopped_partway")

async function runSetup(ctx, res, { signal, startDate, deps }) {
  const me = ctx.session.pubkey, relays = ownPostRelays(ctx.account)
  const parts = deps.importParts ?? importParts
  const r = await partsOrUnreachable(parts, ctx, relays, { startDate, signal, phases: { lanes: true, walk: false, tagged: false }, laneDeadlineMs: deps.laneMs ?? SETUP_LANE_MS }, res)
  res.stored += r.stored
  res.stored += await (deps.currentLists ?? currentLists)(ctx, { signal })
  if (r.failed) res.partial.push("store_failed")
  // The relays whose lane didn't finish: what they hold is read by older_relays, from where each lane got to.
  const left = Object.entries(r.lanes ?? {}).filter(([, l]) => l.how !== "done")
  for (const [relay, l] of left) res.unread.push({ relay, from: startDate, to: day(l.oldest), why: "not_read_yet" })
  res.after.push(f => {
    const older = f.jobs.find(j => j.name === "older_relays")
    older.cursor = { ...(older.cursor ?? {}) }
    for (const [relay, l] of left) older.cursor[relay] = String(l.oldest)
    older.unread = [...older.unread.filter(u => !left.some(([relay]) => relay === u.relay)),
      ...left.map(([relay, l]) => ({ relay, from: startDate, to: day(l.oldest), why: "not_read_yet" }))]
  })
}

/** The follow list and current lists from the account's relays into the vault: the newest of each kind (by d for
 *  30000-range lists). -> how many were stored */
export async function currentLists(ctx, { signal, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const me = ctx.session.pubkey
  const relays = uniq([...(ctx.account?.relays?.write ?? []), ...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
  const evs = await query(relays, { kinds: CURRENT_LIST_KINDS, authors: [me] }, { maxWait: 8000 }).catch(() => [])
  if (signal?.aborted) return 0
  const newest = new Map()
  for (const e of evs) {
    if (e?.pubkey !== me) continue
    const k = e.kind >= 30000 ? `${e.kind}:${(e.tags ?? []).find(t => t[0] === "d")?.[1] ?? ""}` : String(e.kind)
    if (!newest.has(k) || e.created_at > newest.get(k).created_at) newest.set(k, e)
  }
  return storeAll(ctx.vault.outbox, [...newest.values()], { tally: {} })
}

async function runReplies(ctx, res, { signal, startDate, deps }) {
  const me = ctx.session.pubkey, relays = ownPostRelays(ctx.account)
  const done = new Set(Object.entries(res.cursor).filter(([, v]) => v === "done").map(([k]) => k))
  const parts = deps.importParts ?? importParts
  const r = await partsOrUnreachable(parts, ctx, relays, { startDate, signal, phases: { lanes: false, walk: false, tagged: true }, taggedSkip: done }, res)
  res.stored += r.tagged?.stored ?? 0
  if (r.failed) res.partial.push("store_failed")
  for (const [relay, how] of Object.entries(r.taggedHow ?? {})) {
    if (how === "done") res.cursor[relay] = "done"
    else res.unread.push({ relay, from: startDate, to: day(nowSec()), why: lanesWhy(how) })
  }
}

async function runOlderRelays(ctx, res, { signal, startDate, deps }) {
  const me = ctx.session.pubkey
  const walkFrom = new Map(Object.entries(res.cursor).map(([relay, until]) => [relay, Number(until)]).filter(([, u]) => Number.isFinite(u)))
  if (!walkFrom.size) return // nothing setup left behind
  const parts = deps.importParts ?? importParts
  const r = await parts(ctx.vault, me, [...walkFrom.keys()], { startDate, signal, phases: { lanes: false, walk: true, tagged: false }, walkFrom,
    onWalk: (relay, until) => { res.cursor[relay] = String(until); res.checkpoint() } })
  res.stored += r.stored
  if (r.failed) res.partial.push("store_failed")
  const start = Date.parse(`${startDate}T00:00:00Z`) / 1000
  for (const relay of walkFrom.keys()) {
    if (!r.cut.includes(relay)) { delete res.cursor[relay]; continue } // read all the way back
    res.unread.push({ relay, from: startDate, to: day(Math.max(start, Number(res.cursor[relay]))), why: signal?.aborted ? "cut" : "stopped_partway" })
  }
}

async function runWiderNetwork(ctx, res, { deps }) {
  const me = ctx.session.pubkey, follows = ctx.account?.follows ?? []
  const lists = await (deps.followLists ?? (await import("./wot.js")).followLists)(me, follows, { retryMs: 0 })
  res.stored += lists?.size ?? 0
  const missing = follows.filter(pk => !lists?.has?.(pk)).length
  if (missing) res.partial.push("lists_missing")
}

async function runListHistory(ctx, res, { signal, deps }) {
  const run = deps.importListHistory ?? (await import("./list-history-import.js")).importListHistory
  const r = await run(ctx, { history: true, signal })
  res.stored += r.found ?? 0
  if (r.answered < r.asked) res.partial.push("relays_unanswered")
  if (r.skipped) res.partial.push("cut")
}
