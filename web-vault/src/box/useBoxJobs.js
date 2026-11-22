// The box's own jobs for the Vault Dashboard in box mode (One Vault W4; routes in api-jobs.js): its import jobs (Still
// to bring in, and Keep it full's Import notes), its trust rebuild, its backups and Force restart, and keeping its block
// list the signed-in first account's. Each part asks on its own; first-account-only parts are asked only when the box
// says this is the first account, so another account is never asked to sign for a 403.
import { useEffect, useRef, useState } from "preact/hooks"
import { JOB_ORDER, JOB_ESTIMATES, RUN } from "../net/import-jobs.js"
import { npubEncode } from "nostr-tools/nip19"
import { useBlocks } from "../components/useBlocks.js"
import { jobLine } from "../net/import-jobs-words.js"

const blank = name => ({ name, status: "never", stored: 0, unread: [], est_seconds: JOB_ESTIMATES[name] })
/** The box's import_jobs.json in the browser's shape (import-jobs.js loadJobs): every job, in order. */
export const boxJobsFile = f => ({ ...f, jobs: JOB_ORDER.map(name => ({ ...blank(name), ...(f?.jobs ?? []).find(j => j?.name === name), name })) })

const POLL_IDLE = 30_000, POLL_BUSY = 3_000

/** Still to bring in and Import notes on the box: { file, here, busy, note, press, run } (StillToBringInView's props). */
export function useBoxImports(api) {
  const [file, setFile] = useState(() => boxJobsFile(null))
  const [note, setNote] = useState("")
  const load = () => api ? api.imports().then(f => setFile(boxJobsFile(f)), () => {}) : Promise.resolve()
  const running = file.jobs.find(j => j.status === "running")?.name ?? null
  useEffect(() => {
    if (!api) return
    load()
    const t = setInterval(load, running ? POLL_BUSY : POLL_IDLE)
    return () => clearInterval(t)
  }, [api, running])
  const run = async name => {
    setNote("")
    try {
      const r = await api.runImport(name)
      if (r.answered && r.code === RUN.busy) setNote("Another import is running on your box. Run this when it's done.")
      else if (r.answered && r.code !== RUN.started) setNote(r.message ?? "")
      else if (!r.answered) setNote(r.message ?? "")
    } catch (e) { setNote(String(e?.message ?? e)) }
    load()
  }
  const press = async j => {
    if (running === j.name) { await api.cancelImport(j.name).catch(e => setNote(String(e?.message ?? e))); return load() }
    return run(j.name)
  }
  // One job at a time on the box, as in a browser: while one runs, the others wait; the running one offers Cancel.
  return { file, here: running, busy: !!running, note, press, run }
}

/** Who can reach you › Rebuild now: { rebuilding, note, rebuild }. */
export function useBoxTrust(api) {
  const [state, setState] = useState({ rebuilding: false, note: "" })
  const poll = useRef(null)
  useEffect(() => () => clearInterval(poll.current), [])
  const rebuild = async () => {
    setState({ rebuilding: true, note: "" })
    try {
      const r = await api.refreshTrust()
      setState({ rebuilding: r.answered && r.code === 0, note: r.message ?? "" })
      clearInterval(poll.current)
      poll.current = setInterval(() => api.trust().then(t => {
        if (t?.trust?.running) return
        clearInterval(poll.current)
        setState({ rebuilding: false, note: Number.isFinite(t?.trust?.size) ? `Rebuilt: ${t.trust.size.toLocaleString()} ${t.trust.size === 1 ? "person" : "people"}.` : "" })
      }, () => {}), POLL_BUSY)
    } catch (e) { setState({ rebuilding: false, note: String(e?.message ?? e) }) }
  }
  return { ...state, rebuild }
}

/** The box's block list follows the first account's blocks (the box has one list, for every account on it). `blocked`:
 *  hex keys (useBlocks); `loaded`: the blocks are in, so an empty list is real. Sends only when the lists differ. */
export function useBoxBlocklistSync(api, { first, blocked, loaded }) {
  const sent = useRef(null)
  const npubs = [...(blocked ?? [])].map(hex => { try { return npubEncode(hex) } catch { return null } }).filter(Boolean).sort()
  const key = npubs.join(",")
  useEffect(() => {
    if (!api || !first || !loaded || sent.current === key) return
    api.blocklist().then(r => {
      const have = [...(r?.npubs ?? [])].sort().join(",")
      sent.current = key
      if (have !== key) return api.setBlocklist(npubs)
    }).catch(() => {})
  }, [api, first, loaded, key])
}

/** Is the signed-in account the box's first account? `account`: the box vault's boxAccountCheck (box-vault.js). False
 *  until the box says so, so nothing first-account-only is asked before it does. */
export function useBoxFirst(account) {
  const [state, setState] = useState(account?.state)
  useEffect(() => { if (!account) return; setState(account.state); return account.subscribe(n => setState(n.state)) }, [account])
  return state === "first"
}

/** Everything above for the dashboard: null off a box. `box`: useBoxDashboard's answer; `ctx`: the app's. */
export function useBoxJobs(box, ctx) {
  const api = box?.api ?? null
  const first = useBoxFirst(box ? ctx.vault.account : null)
  const imports = useBoxImports(api)
  const trust = useBoxTrust(api)
  const { blocked, loaded } = useBlocks(ctx)
  useBoxBlocklistSync(api, { first, blocked, loaded })
  if (!api) return null
  const setup = imports.file.jobs.find(j => j.name === "setup")
  const restart = () => api.restart().then(() => setTimeout(() => box.load("status"), 4000), e => alert?.(String(e?.message ?? e)))
  return { api, first, imports, trust, restart,
    keepFull: { importing: setup.status === "running" ? { text: "Importing your notes on your box. It keeps going with this page closed." } : null,
      importDetail: jobLine(setup), onImport: () => imports.run("setup") } }
}
