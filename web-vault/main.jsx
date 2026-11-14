// Nostr Vault on the web. Boot: sign-in (NIP-07 / NIP-46, or a key made in Create an account) -> the in-page Haven
// owned by that npub -> the app.
// Every screen reads from Haven; the network only fills Haven. See PLANS/NV_WEB_CLIENT.md.
import { render } from "preact"
import { useEffect, useRef, useState } from "preact/hooks"
import { loadSession, saveSession } from "./src/session.js"
import { signerFor } from "./src/signer/index.js"
import { unlockLocal, wellFormed, DAMAGED } from "./src/signer/local.js"
import { clearAuthUrl } from "./src/signer/nip46.js"
import { painted } from "./src/components/KeyCard.jsx"
import { startVault, forgetThisBrowser, onSignedOutElsewhere, preloadHaven, routeClient, deviceKey } from "./src/haven/vault.js"
import { BOX } from "./src/box/mode.js"
import { startBoxVault } from "./src/box/box-vault.js"
import { BoxScreen } from "./src/box/BoxScreen.jsx"
import { readAccount, refreshAccount, fetchAccount } from "./src/net/sync.js"
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./src/net/pool.js"
import { readKept, keep as keepNeverConnect } from "./src/net/never-connect.js"
import { resetEverything } from "./src/net/reset-all.js"
import { putProfile } from "./src/net/profiles.js"
import { setActionContext } from "./src/net/actions.js"
import { setQuoteSource } from "./src/net/quotes.js"
import { setMeshPeople } from "./src/net/fips-media.js"
import { SetupBringOver } from "./src/screens/SetupBringOver.jsx"
import { WelcomeTour } from "./src/components/WelcomeTour.jsx"
import { NotifyAsk } from "./src/components/NotifyAsk.jsx"
import { markTourDone, tourDone } from "./src/net/first-run.js"
import { runAndWait, resumeImportJobs } from "./src/net/import-jobs.js"
import { FeedScreen } from "./src/screens/FeedScreen.jsx"
import { startNavDepth } from "./src/components/nav-depth.js"
import { ComposeScreen, ProfileScreen, PersonScreen, SearchScreen, NotificationsScreen, ThreadScreen, MessagesScreen, ConversationScreen, VaultScreen, AccountsScreen, WalletScreen, WotScreen, BookmarksScreen, EmojiScreen, RelayScreen, DesktopShell, VaultDashboard, NappletShell, ReaderPane, WotPane } from "./src/screens/lazy-screens.js"
import { nappletsOn } from "./src/napplet/flag.js"
import { readerOpenFor } from "./src/napplet/reader-intents.js"
import { warmScreens } from "./src/screens/warm-screens.js"
import { GuestApp } from "./src/guest/GuestApp.jsx"
import { SettingsScreen, resetBrowser } from "./src/screens/SettingsScreen.jsx"
import { TabBar, PostButton } from "./src/components/TabBar.jsx"
import { tabOf } from "./src/components/tabs.js"
import { startChromeFold } from "./src/components/chrome-fold.js"
import { AuthPrompt } from "./src/components/AuthPrompt.jsx"
import { Splash } from "./src/components/Loading.jsx"
import { UpdateBar } from "./src/components/UpdateBar.jsx"
import { FloatingPlayer } from "./src/readers/FloatingPlayer.jsx"
import { watchUpdates } from "./src/sw-update.js"
import { VaultReady } from "./src/components/VaultReady.jsx"
import { hasLocalData, markPrepared, prepareVault, wasPrepared } from "./src/net/vault-ready.js"
import { deskModeFor, deskRedirect, phoneRedirect, isListHash, withParam } from "./src/desktop/routes.js"
import "./src/styles/app.css"
import "./src/styles/quotes.css"
import "./src/styles/dms.css"
import "./src/styles/settings.css"
import "./src/styles/boot-sheets.js" // after app.css: the sheets the boot components would add later (styles/boot-sheets.js)
import { NotifyWatch } from "./src/components/useNotifyWatch.js"
import { isDashboardOpen } from "./src/net/dashboard-route.js"

// The napplet shell page (plan P1), opened only by its address: /vault/?shell=1.
const NAPPLET_SHELL = new URLSearchParams(location.search).get("shell") === "1"
const ROUTES = ["feed", "search", "wot", "notifications", "compose", "profile", "relay", "thread", "messages", "dm", "vault", "bookmarks", "emoji", "apps", "settings", "accounts", "wallet", ...(BOX ? ["box"] : [])]
// "#/thread/<id>" -> { route: "thread", arg: "<id>" }; "#/profile/<pubkey>" is someone else's profile.
const routeOf = () => {
  const [r, arg = ""] = location.hash.replace(/^#\/?/, "").split(/[?]/)[0].split("/")
  return ROUTES.includes(r) && ((r !== "thread" && r !== "dm") || /^[0-9a-f]{64}$/.test(arg)) && (r !== "profile" || !arg || /^[0-9a-f]{64}$/.test(arg)) ? { route: r, arg } : { route: "feed", arg: "" }
}

// The address the page opened with, before the desktop layout rewrites it: a shared post's link carries its relay
// hints there (src/guest). Someone signed in starts downloading haven.wasm now; a guest never needs it.
const bootHash = location.hash
// Compose closes back to the page it came from, or shows Done when it was the first page (src/components/nav-depth.js).
startNavDepth()
if (loadSession() && !BOX) preloadHaven() // a box's vault is the box: no haven.wasm

// 760px and up is the desktop layout (src/desktop). The address is fixed up for the layout before anything renders:
// a thread link opens beside the list it came from on a wide window, and a desktop address with a note open goes to
// the phone's thread screen on a narrow one. `lastList` is the list screen a thread or Compose opens over.
let lastList = null
function settle(mode) {
  const fix = mode === "phone" ? phoneRedirect(location.hash) : deskRedirect(location.hash, lastList)
  if (fix) history.replaceState(history.state, "", fix)
  // The dashboard sheet (?sheet=dashboard) is over the list, not part of it: a note opened later doesn't reopen it.
  if (mode !== "phone" && isListHash(location.hash)) lastList = withParam(location.hash, "sheet", null)
  return routeOf()
}
function useDeskMode() {
  const [mode, setMode] = useState(() => deskModeFor(innerWidth))
  useEffect(() => { const f = () => setMode(deskModeFor(innerWidth)); addEventListener("resize", f); return () => removeEventListener("resize", f) }, [])
  return mode
}

// Kept in localStorage so a phone run can be read back over CDP; nothing leaves the device.
const logLines = JSON.parse(localStorage.getItem("nv-log") || "[]")
// Only while someone is signed in: off once sign-out has deleted the log, so nothing still running writes it back,
// and off on the sign-in screen that sign-out reloads into, so nothing written at boot brings it back either.
let logging = !!loadSession()
// A new account's first events (net/new-account.js), signed in Create an account: written into Haven's outbox as it
// starts, so the first feed has its follows before any relay answers.
let firstEvents = null
function log(type, data = {}) {
  if (!logging) return
  logLines.push({ t: new Date().toISOString(), type, ...data })
  while (logLines.length > 300) logLines.shift()
  localStorage.setItem("nv-log", JSON.stringify(logLines))
}
globalThis.nvLog = logLines

function App() {
  const [session, setSession] = useState(loadSession)
  const [signer, setSigner] = useState(() => session && signerFor(session, pool))
  const signerNow = useRef(signer); signerNow.current = signer // box mode signs the box relay's AUTH with whichever signer is current
  const [vault, setVault] = useState(null)
  const [account, setAccount] = useState(null)
  const [error, setError] = useState("")
  const mode = useDeskMode()
  const modeNow = useRef(mode)
  modeNow.current = mode
  const [{ route, arg }, setRoute] = useState(() => settle(mode))
  const [leaving, setLeaving] = useState(null) // sign-out in progress: { busy } | { failed, revoked }
  // First sign-in on this browser: { [step]: { state, done, of, count } } while Haven fills (net/vault-ready.js).
  const [prep, setPrep] = useState(null)
  // First sign-in: the import choice (relays, a backup, or copy from my other vault) before the steps ({ pubkey, liveOwners, done }), and
  // the line it leaves for the steps screen.
  const [askOther, setAskOther] = useState(null)
  const [prepNote, setPrepNote] = useState(null)
  // A new account's short tour, once, after it's in; the notification question waits until it's closed.
  const [tour, setTour] = useState(false)
  const openNow = useRef(null)
  // A key made here whose sealed copy this browser can't open any more: the password opens its ncryptsec again.
  const [locked, setLocked] = useState(false)
  useEffect(() => { if (session?.method === "local") signer?.ready?.().catch(() => setLocked(true)) }, [signer])

  useEffect(() => { const f = () => setRoute(settle(modeNow.current)); addEventListener("hashchange", f); return () => removeEventListener("hashchange", f) }, [])
  // Crossing 760px swaps layouts; the address is fixed up for the new one.
  useEffect(() => { setRoute(settle(mode)) }, [mode === "phone"])
  // The phone's bars fold as you scroll, as on the iPhone (chrome-fold.js); the desktop layout has none.
  useEffect(() => mode === "phone" && session ? startChromeFold() : undefined, [mode === "phone", !!session])
  // Who Can Reach You (the FIPS panel) is fetched, and mounted, the first time it is opened, then stays mounted: its
  // panel finds its elements once, by id, and the mesh keeps running while the user is elsewhere in the app.
  const [relayShown, setRelayShown] = useState(route === "relay")
  useEffect(() => { if (route === "relay") setRelayShown(true) }, [route])

  useEffect(() => {
    if (!session) return
    let live = true
    // Never Connect holds from the first socket: the list this browser kept last time, until the account's own arrives.
    pool.setNeverConnect(readKept(session.pubkey))
    // The account's relays are asked while haven.wasm downloads (seconds on a first visit), not after Haven is up.
    const early = navigator.onLine ? fetchAccount(session.pubkey, uniq([...DEFAULT_RELAYS, ...PROFILE_RELAYS])) : null
    // An account this browser hasn't prepared gets the steps screen from the start, not the splash, so starting the
    // relay is its first step. A later sign-in keeps the splash and opens as soon as Haven is up.
    const step = (id, s) => setPrep(p => p && { ...p, [id]: { ...p[id], ...s } })
    const firstTime = navigator.onLine && !wasPrepared(session.pubkey)
    if (firstTime) setPrep({ relay: { state: "active" } })
    // Open now: the app opens on what Haven has (as soon as Haven is up), and the steps carry on in the background.
    let opened = !firstTime, shown = null
    // The account came back with no follow list while a relay was still to answer (sync.js refreshAccount onLate): this
    // is it once they all have. Loaded either way then: a list nobody has is an account that follows no one.
    // It can land before prepareVault returns (its setup runs on), so the account set after that keeps it.
    let late = null, read = null
    const lateAccount = acc => {
      if (!live) return
      late = acc
      putProfile(acc.profileEvent)
      setAccount({ ...acc, loaded: true })
      log("account", { follows: acc.follows.length, late: true })
    }
    const settled = acc => late ? { ...late, loaded: true } : { ...acc, loaded: !!acc.contacts }
    const current = () => late ? { ...late, loaded: true } : read ? settled(read) : shown
    openNow.current = () => { if (opened) return; opened = true; setPrep(null); if (shown) setAccount(current()) }
    // Setup has read the account (its first step) while the rest runs on: an app already opened shows it now.
    const accountRead = acc => { if (!live) return; read = acc; putProfile(acc.profileEvent); if (opened) setAccount(current()) }
    ;(async () => {
      const v = BOX ? startBoxVault({ signer: { signEvent: e => signerNow.current.signEvent(e) }, routeClient, deviceKey }) : await startVault({ pubkey: session.pubkey, log })
      if (!live) return
      log("boot", { loadMs: v.loadMs, startMs: v.startMs, method: session.method })
      setVault(v)
      const madeHere = !!firstEvents
      if (madeHere && !tourDone(session.pubkey)) setTour(true)
      if (firstEvents) {
        for (const ev of firstEvents) await v.outbox.event(ev).catch(e => log("first-event-error", { kind: ev.kind, err: String(e) }))
        firstEvents = null
      }
      const local = await readAccount(v, session.pubkey)
      putProfile(local.profileEvent)
      setQuoteSource({ vault: v, relays: uniq([...local.relays.read, ...DEFAULT_RELAYS]) }) // quoted notes and mention names (NoteText)
      shown = { ...local, loaded: !!local.contacts }
      if (firstTime && !opened && !(await hasLocalData(v, local))) {
        step("relay", { state: "done" })
        // An account made here a moment ago has nothing to bring in; box mode has its own setup.
        if (!BOX && !madeHere) {
          const { note } = await new Promise(done => setAskOther({ pubkey: session.pubkey, vault: v, liveOwners: v.owners, done }))
          setAskOther(null)
          setPrepNote(note)
          if (!live) return
        }
        const { account: ready, fresh } = await prepareVault({ vault: v, pubkey: session.pubkey, local, early, log, onStep: step,
          setup: c => runAndWait(c, "setup"), onLate: lateAccount, onAccount: accountRead })
        if (!live) return
        if (fresh) {
          putProfile(ready.profileEvent)
          setAccount(settled(ready)) // no follow list yet: "Loading your follows…" until onLate
          setPrep(null)
          log("account", { follows: ready.follows.length, cachedFollows: local.follows.length, prepared: true })
          return
        }
        // The account step was too slow: open on what Haven has and let the refresh below finish it.
      }
      if (firstTime) markPrepared(session.pubkey)
      setPrep(null)
      setAccount(late ? { ...late, loaded: true } : shown)
      if (!navigator.onLine) return
      const fresh = await refreshAccount(v, session.pubkey, uniq([...local.relays.read, ...local.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { log, early, onLate: lateAccount })
      putProfile(fresh.profileEvent)
      if (live) setAccount(settled(fresh))
      log("account", { follows: fresh.follows.length, cachedFollows: local.follows.length })
    })().catch(e => { log("boot-error", { err: String(e) }); setError(String(e?.message ?? e)) })
    return () => { live = false }
  }, [session?.pubkey])

  // An approval link the user never tapped (they approved in the bunker app) is done with once sign-in succeeds.
  const onSignedIn = ({ signer, session, firstEvents: first }) => { firstEvents = first ?? null; logging = true; clearAuthUrl(); saveSession(session); setSigner(signer); setSession(session); log("signed-in", { method: session.method }); registerWorker() }
  const restart = () => location.replace(location.pathname)

  // Another tab signed out (or in as someone else): stop this tab's Haven so that tab's deletes can finish, and
  // don't write anything back.
  useEffect(() => session && onSignedOutElsewhere(session.pubkey, async () => {
    logging = false
    await vault?.haven.stop().catch(() => {})
    signer?.close?.()
    restart()
  }), [session?.pubkey, vault, signer])

  // Anything that throws lands on the sign-out screen with its buttons, never on a splash with none.
  // `all` (Settings › Reset Everything): every account on this browser and this app's settings, not just this one.
  // A click handler may pass its event here: only an explicit { all: true } resets everything.
  const wipe = all => all ? resetEverything({ vault, pubkey: session.pubkey, pool }) : forgetThisBrowser({ vault, pubkey: session.pubkey })
  const signOut = async opts => {
    const all = opts?.all === true
    setLeaving({ busy: true, all })
    logging = false
    let revoked = null
    try {
      // A bunker is asked to drop this browser's grant; null means there was no grant to drop (extension).
      revoked = signer?.revoke ? await signer.revoke() : (signer?.close?.(), null)
      const { failed, revokeFailed = 0 } = await wipe(all)
      if (revokeFailed) revoked = false
      if (failed.length || revoked === false) setLeaving({ failed, revoked, all })
      else restart()
    } catch (e) {
      setLeaving({ failed: [], revoked, all, error: String(e?.message ?? e) })
    }
  }
  const retryWipe = async () => {
    setLeaving(l => ({ ...l, busy: true, error: "" }))
    try {
      const { failed } = await wipe(leaving?.all)
      setLeaving(l => ({ ...l, busy: false, failed }))
    } catch (e) {
      setLeaving(l => ({ ...l, busy: false, error: String(e?.message ?? e) }))
    }
  }

  if (leaving) return <SignOutScreen {...leaving} onRetry={retryWipe} onDone={restart} />
  if (locked) return <UnlockScreen session={session} onUnlocked={s => { saveSession(s); setSigner(signerFor(s, pool)); setSession(s); setLocked(false) }} onSignOut={signOut} />
  // Not signed in: the welcome screen, and the posts and people a guest can look at (src/guest), until they sign in.
  if (!session) return <GuestApp bootHash={bootHash} onSignedIn={onSignedIn} />
  if (error) return <main class="screen"><p class="error">Your relay didn't start: {error}</p><button onClick={() => location.reload()}>Try again</button></main>
  if (askOther) return <SetupBringOver pubkey={askOther.pubkey} vault={askOther.vault} liveOwners={askOther.liveOwners} onDone={askOther.done} />
  if (prep) return <VaultReady steps={prep} note={prepNote} onOpen={() => openNow.current ? openNow.current() : setPrep(null)} />
  if (!vault || !account) return <Splash>Starting your relay…</Splash>

  // A Vault job (import-jobs.js) a reload or a closed tab cut is picked up once the account is in, from its cursor.
  useEffect(() => { if (!BOX && account?.loaded) resumeImportJobs({ vault, session, account }).catch(() => {}) }, [session?.pubkey, !!account?.loaded])

  // The tab screens' code, fetched while the app is idle, so a first click on a tab doesn't flash placeholder rows.
  useEffect(() => { warmScreens() }, [])

  // After a follow or unfollow: the new list is in Haven's outbox, so read the account back and the feed follows it.
  // The account's Never Connect list (kind 10006), from Haven or the network: the pool refuses those relays.
  useEffect(() => {
    if (!account?.neverConnect || !session) return
    pool.setNeverConnect(account.neverConnect)
    keepNeverConnect(session.pubkey, account.neverConnect)
  }, [session?.pubkey, (account?.neverConnect ?? []).join(" "), !!account?.neverConnect])
  const reloadAccount = async () => setAccount({ ...(await readAccount(vault, session.pubkey)), loaded: true })
  const ctx = { vault, session, signer, account, signOut, reloadAccount }
  setActionContext(ctx)
  setMeshPeople(session.pubkey, account.follows) // whose note photos may load over FIPS (MediaImage)
  // ?shell=1: the napplet shell page instead of the app's screens (src/napplet, plan P1). Hidden: nothing links it.
  if (NAPPLET_SHELL) return <div class="app"><NappletShell ctx={ctx} /><AuthPrompt /></div>
  const other = route === "profile" && arg && arg !== session.pubkey // someone else's profile, reached from Search
  const desk = mode !== "phone"
  // The relay screen stays mounted (its FIPS panel finds its elements once, by id), in the same place in both layouts.
  return (
    <div class={desk ? "app desk-app" : "app"}>
      <NotifyWatch ctx={ctx} />
      {desk ? <DesktopShell ctx={ctx} mode={mode} hash={location.hash} lastList={lastList} /> : <PhoneScreens ctx={ctx} route={route} arg={arg} other={other} />}
      {/* A box has its own mesh and no in-page relay: its Box screen (src/box) instead of the browser relay's. */}
      {BOX ? (route === "box" || route === "relay") && <div class="box-host"><BoxScreen ctx={ctx} /></div>
        : <div class="relay-host" hidden={route !== "relay"}>{relayShown && <RelayScreen ctx={ctx} log={log} />}</div>}
      {!desk && (route === "feed" && !readsInNapplet(route, other) || route === "search" || route === "profile" && !other) && !signer?.readOnly && <PostButton />}
      {!desk && <TabBar ctx={ctx} route={tabOf(route, other)} pubkey={session.pubkey} />}
      <FloatingPlayer />
      {isDashboardOpen() && <VaultDashboard ctx={ctx} />}
      <AuthPrompt />
      {tour && <WelcomeTour onDone={() => { markTourDone(session.pubkey); setTour(false) }} />}
      {!BOX && <NotifyAsk busy={tour} />}
    </div>
  )
}

/** The WoT tab as the WoT napplet (plan P6): with the switch on, except "See their web" (#/wot/<hex>/web), still classic. */
const wotInNapplet = (hash = location.hash) => nappletsOn() && !/^#\/wot\/[0-9a-f]{64}\/web/.test(hash)

/** Does this screen show as the Reader napplet? Only with the switch on, and never your own profile (its editor stays). */
const readsInNapplet = (route, other) => nappletsOn() && (route === "feed" || route === "thread" || (route === "profile" && !!other))

/** The phone layout's screens, one at a time, as before the desktop layout existed. */
function PhoneScreens({ ctx, route, arg, other }) {
  // The napplet switch on: Feed, Thread and someone's Profile are the Reader napplet, one element so it stays mounted
  // as you move between them (plan P4). Off: the screens below, unchanged.
  const reader = readsInNapplet(route, other)
  return (
    <>
      {reader && <ReaderPane ctx={ctx} open={readerOpenFor(route, arg)} />}
      {!reader && route === "feed" && <FeedScreen ctx={ctx} />}
      {route === "compose" && <ComposeScreen ctx={ctx} />}
      {!reader && route === "profile" && (other ? <PersonScreen key={arg} ctx={ctx} pubkey={arg} /> : <ProfileScreen ctx={ctx} />)}
      {route === "wot" && (wotInNapplet() ? <WotPane ctx={ctx} open={/^[0-9a-f]{64}$/.test(arg) ? arg : null} /> : <WotScreen ctx={ctx} pubkey={/^[0-9a-f]{64}$/.test(arg) ? arg : undefined} />)}
      {route === "search" && <SearchScreen ctx={ctx} onProfile={pk => { location.hash = `#/profile/${pk}` }} />}
      {route === "notifications" && <NotificationsScreen ctx={ctx} vaultMenu />}
      {!reader && route === "thread" && <ThreadScreen key={arg} ctx={ctx} id={arg} />}
      {route === "messages" && <MessagesScreen ctx={ctx} vaultMenu />}
      {route === "bookmarks" && <BookmarksScreen ctx={ctx} />}
      {route === "emoji" && <EmojiScreen ctx={ctx} />}
      {route === "apps" && <NappletShell ctx={ctx} showSwitch={false} vaultMenu />}
      {route === "dm" && <ConversationScreen key={arg} ctx={ctx} peer={arg} />}
      {route === "vault" && <VaultScreen ctx={ctx} />}
      {route === "settings" && <SettingsScreen key={arg} ctx={ctx} page={arg} />}
      {route === "accounts" && <AccountsScreen ctx={ctx} />}
      {route === "wallet" && <WalletScreen />}
    </>
  )
}

/** A key made in Create an account, locked: its password opens the ncryptsec (signer/local.js unlockLocal). */
function UnlockScreen({ session, onUnlocked, onSignOut }) {
  const [pw, setPw] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  // Signing out here deletes the only copy of this key: ask first, in the Settings wipe's words.
  const leave = () => resetBrowser({ session, signOut: onSignOut })
  // No password opens a missing or damaged key: say so once, and leave only Sign out.
  const [damaged, setDamaged] = useState(() => !wellFormed(session?.ncryptsec))
  const submit = async e => {
    e.preventDefault()
    setBusy(true); setErr("")
    await painted() // opening the key is scrypt, which holds the page for a moment: show "Unlocking…" first
    try { onUnlocked(await unlockLocal(session, pw)) }
    catch (e) { if (e?.message === DAMAGED) setDamaged(true); else setErr(String(e?.message ?? e)) }
    finally { setBusy(false) }
  }
  if (damaged) return (
    <main class="signin">
      <img src="./icon.svg" alt="" class="signin-logo" />
      <h1>Your key can't be opened</h1>
      <p class="muted" role="alert">{DAMAGED}</p>
      <button class="danger" onClick={leave}>Sign out</button>
    </main>
  )
  return (
    <main class="signin">
      <img src="./icon.svg" alt="" class="signin-logo" />
      <h1>Unlock your key</h1>
      <p class="muted">This browser can't open your key on its own any more (its site data was partly cleared). Type the password you chose when you made the account.</p>
      <form onSubmit={submit} style="display: contents">
        <input type="text" name="username" autocomplete="username" value="Nostr Vault key" hidden readOnly />
        <label class="field"><span>Password</span>
          <input type="password" value={pw} onInput={e => setPw(e.currentTarget.value)} autocomplete="current-password" required /></label>
        <button type="submit" class="primary" disabled={busy || !pw} aria-busy={busy || undefined}>{busy ? "Unlocking…" : "Unlock"}</button>
      </form>
      {err && <p class="error">{err}</p>}
      <button class="danger" onClick={leave}>Sign out instead</button>
    </main>
  )
}

// Sign-out says plainly what it couldn't do: a store still open (another tab) or a bunker grant still live.
function SignOutScreen({ busy, failed = [], revoked, error, onRetry, onDone }) {
  if (busy && !failed.length) return <Splash>Signing out…</Splash>
  return (
    <main class="screen">
      <h2>Signing out</h2>
      {failed.length > 0 && <>
        <p class="error">{failed.length} of this browser's stores weren't deleted, so your relay's data is still here. This usually means Nostr Vault is open in another tab or window. Close it, then try again.</p>
        <pre class="muted small">{failed.join("\n")}</pre>
        <button class="primary" disabled={busy} onClick={onRetry}>{busy ? "Deleting…" : "Try again"}</button>
      </>}
      {error && <>
        <p class="error">Sign-out stopped partway: {error}. Some of this browser's data may still be here.</p>
        <button class="primary" disabled={busy} onClick={onRetry}>{busy ? "Deleting…" : "Try again"}</button>
      </>}
      {revoked === false && <p class="muted">Your bunker didn't confirm it dropped this browser's connection. To be sure, revoke it in your bunker app.</p>}
      {!failed.length && !error && <p class="muted">Everything this browser kept for your account is deleted.</p>}
      <button disabled={busy} onClick={onDone}>{failed.length || error ? "Leave it and go to sign-in" : "Done"}</button>
    </main>
  )
}

// Registered once the page has loaded: the worker's install fetches every file index.html links, and by then they're
// in the HTTP cache instead of downloading a second time beside the page's own. Only for someone signed in (now, or on
// sign-in): a guest's browser keeps no copy of the app.
let workerAsked = false
function registerWorker() {
  if (workerAsked || !("serviceWorker" in navigator)) return
  workerAsked = true
  navigator.serviceWorker.register("./sw.js").then(reg => watchUpdates(reg, navigator.serviceWorker)).catch(e => log("sw-error", { err: String(e) }))
}
if (loadSession()) document.readyState === "complete" ? registerWorker() : addEventListener("load", registerWorker, { once: true })
if (loadSession()) navigator.storage?.persist?.().then(granted => log("persist", { granted }))
// A newer build in another tab opened Haven's stores at a higher version: haven-go/idbstore closed them here so that
// tab isn't blocked, and this one reloads onto the new build. Sign-out deletes the stores too, but drops the session
// first; onSignedOutElsewhere handles that.
addEventListener("idbstore-versionchange", () => { if (loadSession()) location.reload() }, { once: true })
render(<><App /><UpdateBar /></>, document.getElementById("app"))
