// First sign-in on this browser: Haven starts empty, so the app would open on half-empty screens while the network
// fills it. prepareVault fills it first, step by step, for the "Getting your vault ready" screen
// (components/VaultReady.jsx). A later sign-in skips it: this browser has done it once for the account, or Haven
// already holds the account's follow list and some of their notes.
import { readFeed, refreshAccount, syncFeed, syncOwn } from "./sync.js"
import { fetchProfiles } from "./profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"

/** The steps, in the order the screen lists them. */
export const STEPS = [
  { id: "relay", title: "Starting your relay" },
  { id: "account", title: "Finding your account" },
  { id: "notes", title: "Fetching your notes" },
  { id: "feed", title: "Fetching notes from people you follow" },
  { id: "profiles", title: "Loading names and pictures" },
]

// How long a step may hold the screen. A slow one carries on in the background and the app opens anyway: the
// Feed's own sync and each screen's profile reads pick up whatever it hadn't stored yet.
export const STEP_LIMIT_MS = { account: 12_000, notes: 12_000, feed: 25_000, profiles: 15_000 }
const PROFILE_CHUNK = 200 // fetchProfiles' own batch, asked one at a time so the screen can count them

// Accounts this browser has prepared once, so their next sign-in opens straight away. Sign-out removes it
// (haven/vault.js LOCAL_KEYS).
export const READY_KEY = "nv-ready"
const readyList = storage => { try { return JSON.parse(storage.getItem(READY_KEY) ?? "[]") } catch { return [] } }
export const wasPrepared = (pubkey, storage = localStorage) => readyList(storage).includes(pubkey)
export function markPrepared(pubkey, storage = localStorage) {
  const list = readyList(storage)
  if (!list.includes(pubkey)) storage.setItem(READY_KEY, JSON.stringify([...list, pubkey]))
}

/** Does Haven already hold enough to open on? The follow list, and a note from them when they follow anyone. */
export async function hasLocalData(vault, account) {
  if (!account?.contacts) return false
  if (!account.follows.length) return true
  return (await readFeed(vault, account.follows, { limit: 1 })).length > 0
}

/** `p` once it settles, or "slow" after `ms`; `p` keeps running either way. */
function within(p, ms) {
  let timer
  return Promise.race([p.then(() => "done", () => "failed"), new Promise(r => { timer = setTimeout(() => r("slow"), ms) })]).finally(() => clearTimeout(timer))
}

/**
 * Fill Haven for a first sign-in: the account (kind 0, 3, 10002), then the user's own notes, their follows' notes
 * and their follows' profiles at once. `onStep(id, { state, done, of, count })` reports each step: state is
 * "active", "done", "slow" (still going in the background) or "failed". -> the account as refreshAccount read it back
 */
export async function prepareVault({ vault, pubkey, local, early, log = () => {}, onStep = () => {}, limits = STEP_LIMIT_MS }) {
  // A step that has reported its end stays ended: a slow sync still counting in the background doesn't reopen it.
  const ended = new Set()
  const say = (id, s) => {
    if (ended.has(id)) return
    if (s.state !== "active") ended.add(id)
    onStep(id, s)
  }
  say("account", { state: "active" })
  const accountRun = refreshAccount(vault, pubkey, uniq([...local.relays.read, ...local.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { log, early })
  const accountState = await within(accountRun, limits.account)
  // Too slow or failed: go on with what Haven has, and the boot's own refresh brings the rest.
  const account = accountState === "done" ? await accountRun : local
  say("account", { state: accountState, count: account.follows.length })

  const readRelays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const writeRelays = uniq([...account.relays.write, ...account.relays.read, ...DEFAULT_RELAYS])
  const run = async (id, work) => {
    say(id, { state: "active" })
    const state = await within(work, limits[id])
    say(id, { state })
    log("prepare", { step: id, state })
  }

  const follows = account.follows
  const notes = run("notes", syncOwn(vault, pubkey, writeRelays).then(n => say("notes", { state: "active", count: n })))
  const feed = follows.length
    ? run("feed", syncFeed(vault, follows, readRelays, { onProgress: p => say("feed", { state: "active", done: p.done, of: p.of, count: p.stored }) }))
    : (say("feed", { state: "done", count: 0 }), Promise.resolve())
  const profiles = follows.length
    ? run("profiles", (async () => {
        for (let i = 0; i < follows.length; i += PROFILE_CHUNK) {
          await fetchProfiles(vault, follows.slice(i, i + PROFILE_CHUNK), readRelays)
          say("profiles", { state: "active", done: Math.min(i + PROFILE_CHUNK, follows.length), of: follows.length })
        }
      })())
    : (say("profiles", { state: "done" }), Promise.resolve())
  await Promise.all([notes, feed, profiles])
  markPrepared(pubkey)
  return { account, fresh: accountState === "done" }
}

/** 0..1 across every step, for the progress bar: a step with a count moves within its share. */
export function progressOf(steps) {
  const share = 1 / STEPS.length
  return STEPS.reduce((sum, { id }) => {
    const s = steps[id]
    if (!s) return sum
    if (s.state !== "active") return sum + share
    return sum + share * (s.of ? Math.min(s.done / s.of, 1) * 0.9 : 0.15)
  }, 0)
}
