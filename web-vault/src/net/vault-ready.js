// First sign-in on this browser: Haven starts empty, so the app would open on half-empty screens while the network
// fills it. prepareVault fills it first, step by step, for the "Getting your vault ready" screen
// (components/VaultReady.jsx), and lets the app open once the first page of the feed and those authors' names are
// in: the rest of the fill carries on behind it (backgroundFill), as waiting for all of it took 20 s and more for
// 1,000 follows. A later sign-in skips it: this browser has done it once for the account, or Haven
// already holds the account's follow list and some of their notes.
import { readFeed, refreshAccount, syncFeed, syncOwn } from "./sync.js"
import { fetchProfiles, namesIn } from "./profiles.js"
import { noteAuthors } from "./feeds.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { ownPostRelays } from "./own-relays.js"

/** The steps, in the order the screen lists them. */
export const STEPS = [
  { id: "relay", title: "Starting your relay" },
  { id: "account", title: "Finding your account" },
  { id: "notes", title: "Fetching your notes" },
  { id: "feed", title: "Fetching notes from people you follow" },
  { id: "profiles", title: "Loading names and pictures" },
]

// How long a step may hold the screen (feed's is also how long the first page and its names may). A slow one carries
// on in the background and the app opens anyway: the Feed's own sync and each screen's profile reads pick up whatever
// it hadn't stored yet.
export const STEP_LIMIT_MS = { account: 12_000, notes: 12_000, feed: 25_000, profiles: 15_000 }
const PROFILE_CHUNK = 200 // fetchProfiles' own batch, asked in turn per lane so the screen can count them
const PROFILES_AT_ONCE = 2
/** The first page: as many notes as the Feed reads at once (FeedScreen PAGE). */
export const FIRST_PAGE = 100

// The feed fill a first sign-in leaves running once the app opens. The Feed's sync joins it, redrawing as it stores,
// rather than starting a second one.
let filling = null
export const backgroundFill = () => filling

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
 * Fill Haven for a first sign-in: the account (kind 0, 3, 10002, 10006), then the user's own notes, their follows' notes
 * and their follows' profiles at once. `onStep(id, { state, done, of, count })` reports each step: state is
 * "active", "done", "slow" (still going in the background) or "failed". Returns once the first page of the feed and
 * its authors' names are stored (or the feed step's limit passes); the steps carry on after it and keep reporting.
 * -> { account as refreshAccount read it back, fresh, filled: settles once every step has ended }
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
  // Their own old posts: from the relays their list names (write or unmarked, public only) and the apps' five.
  const writeRelays = ownPostRelays(account)
  const run = async (id, work) => {
    say(id, { state: "active" })
    const state = await within(work, limits[id])
    say(id, { state })
    log("prepare", { step: id, state })
  }

  const follows = account.follows
  const notes = run("notes", syncOwn(vault, pubkey, writeRelays).then(n => say("notes", { state: "active", count: n })))
  if (!follows.length) {
    say("feed", { state: "done", count: 0 })
    say("profiles", { state: "done" })
    await notes
    markPrepared(pubkey)
    return { account, fresh: accountState === "done", filled: notes }
  }

  // The first page is in once a page of notes is stored or the first group of follows has answered, whichever is first.
  let firstPage
  const firstStored = new Promise(r => { firstPage = r })
  const joined = new Set()
  const feedWork = syncFeed(vault, follows, readRelays, {
    onFirstPage: () => firstPage(),
    onProgress: p => {
      if (p.stored >= FIRST_PAGE) firstPage()
      say("feed", { state: "active", done: p.done, of: p.of, count: p.stored })
      for (const cb of joined) cb(p)
    },
  })
  feedWork.then(firstPage, firstPage)
  const fill = { join: cb => { joined.add(cb); return feedWork.finally(() => joined.delete(cb)) } }
  filling = fill
  feedWork.catch(() => {}).finally(() => { if (filling === fill) filling = null })
  const feed = run("feed", feedWork)

  // Names for the first page's authors (and the people their reposts are of) go out before the rest of the follows'.
  const firstNames = firstStored.then(async () => {
    const authors = uniq(noteAuthors(await readFeed(vault, follows, { limit: FIRST_PAGE })))
    await namesIn(authors, fetchProfiles(vault, authors, readRelays))
  })
  // Then everyone else's, PROFILES_AT_ONCE groups at a time (one after another took ~6 s per group of 200).
  const starts = Array.from({ length: Math.ceil(follows.length / PROFILE_CHUNK) }, (_, k) => k * PROFILE_CHUNK).values()
  let named = 0
  const profiles = run("profiles", within(firstNames, limits.feed).then(() => Promise.all(Array.from({ length: PROFILES_AT_ONCE }, async () => {
    for (const i of starts) {
      await fetchProfiles(vault, follows.slice(i, i + PROFILE_CHUNK), readRelays)
      named = Math.min(named + PROFILE_CHUNK, follows.length)
      say("profiles", { state: "active", done: named, of: follows.length })
    }
  }))))

  const opening = await within(firstNames, limits.feed)
  log("prepare", { step: "open", state: opening })
  markPrepared(pubkey)
  return { account, fresh: accountState === "done", filled: Promise.all([notes, feed, profiles]) }
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
