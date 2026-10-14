// Nostr Vault on the web. Boot: sign-in (NIP-07 / NIP-46) -> the in-page Haven owned by that npub -> the app.
// Every screen reads from Haven; the network only fills Haven. See PLANS/NV_WEB_CLIENT.md.
import { render } from "preact"
import { useEffect, useState } from "preact/hooks"
import { loadSession, saveSession } from "./src/session.js"
import { signerFor } from "./src/signer/index.js"
import { clearAuthUrl } from "./src/signer/nip46.js"
import { startVault, forgetThisBrowser, onSignedOutElsewhere } from "./src/haven/vault.js"
import { readAccount, refreshAccount } from "./src/net/sync.js"
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./src/net/pool.js"
import { putProfile } from "./src/net/profiles.js"
import { setActionContext } from "./src/net/actions.js"
import { setQuoteSource } from "./src/net/quotes.js"
import { SignInScreen } from "./src/screens/SignInScreen.jsx"
import { FeedScreen } from "./src/screens/FeedScreen.jsx"
import { ComposeScreen } from "./src/screens/ComposeScreen.jsx"
import { ProfileScreen } from "./src/screens/ProfileScreen.jsx"
import { RelayScreen } from "./src/screens/RelayScreen.jsx"
import { SearchScreen } from "./src/screens/SearchScreen.jsx"
import { NotificationsScreen } from "./src/screens/NotificationsScreen.jsx"
import { ThreadScreen } from "./src/screens/ThreadScreen.jsx"
import { MessagesScreen } from "./src/screens/MessagesScreen.jsx"
import { ConversationScreen } from "./src/screens/ConversationScreen.jsx"
import { PersonScreen } from "./src/screens/PersonScreen.jsx"
import { VaultScreen } from "./src/screens/VaultScreen.jsx"
import { SettingsScreen } from "./src/screens/SettingsScreen.jsx"
import { AccountsScreen } from "./src/screens/AccountsScreen.jsx"
import { TabBar, PostButton } from "./src/components/TabBar.jsx"
import { AuthPrompt } from "./src/components/AuthPrompt.jsx"
import "./src/styles/app.css"
import "./src/styles/quotes.css"
import "./src/styles/dms.css"
import "./src/styles/settings.css"

const ROUTES = ["feed", "search", "notifications", "compose", "profile", "relay", "thread", "messages", "dm", "vault", "settings", "accounts"]
// "#/thread/<id>" -> { route: "thread", arg: "<id>" }; "#/profile/<pubkey>" is someone else's profile.
const routeOf = () => {
  const [r, arg = ""] = location.hash.replace(/^#\/?/, "").split(/[?]/)[0].split("/")
  return ROUTES.includes(r) && ((r !== "thread" && r !== "dm") || /^[0-9a-f]{64}$/.test(arg)) && (r !== "profile" || !arg || /^[0-9a-f]{64}$/.test(arg)) ? { route: r, arg } : { route: "feed", arg: "" }
}

// Kept in localStorage so a phone run can be read back over CDP; nothing leaves the device.
const logLines = JSON.parse(localStorage.getItem("nv-log") || "[]")
// Only while someone is signed in: off once sign-out has deleted the log, so nothing still running writes it back,
// and off on the sign-in screen that sign-out reloads into, so nothing written at boot brings it back either.
let logging = !!loadSession()
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
  const [vault, setVault] = useState(null)
  const [account, setAccount] = useState(null)
  const [error, setError] = useState("")
  const [{ route, arg }, setRoute] = useState(routeOf)
  const [leaving, setLeaving] = useState(null) // sign-out in progress: { busy } | { failed, revoked }

  useEffect(() => { const f = () => setRoute(routeOf()); addEventListener("hashchange", f); return () => removeEventListener("hashchange", f) }, [])

  useEffect(() => {
    if (!session) return
    let live = true
    ;(async () => {
      const v = await startVault({ pubkey: session.pubkey, log })
      if (!live) return
      log("boot", { loadMs: v.loadMs, startMs: v.startMs, method: session.method })
      setVault(v)
      const local = await readAccount(v, session.pubkey)
      putProfile(local.profileEvent)
      setQuoteSource({ vault: v, relays: uniq([...local.relays.read, ...DEFAULT_RELAYS]) }) // quoted notes and mention names (NoteText)
      setAccount({ ...local, loaded: !!local.contacts })
      if (!navigator.onLine) return
      const fresh = await refreshAccount(v, session.pubkey, uniq([...local.relays.read, ...local.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { log })
      putProfile(fresh.profileEvent)
      if (live) setAccount({ ...fresh, loaded: true })
      log("account", { follows: fresh.follows.length, cachedFollows: local.follows.length })
    })().catch(e => { log("boot-error", { err: String(e) }); setError(String(e?.message ?? e)) })
    return () => { live = false }
  }, [session?.pubkey])

  // An approval link the user never tapped (they approved in the bunker app) is done with once sign-in succeeds.
  const onSignedIn = ({ signer, session }) => { logging = true; clearAuthUrl(); saveSession(session); setSigner(signer); setSession(session); log("signed-in", { method: session.method }) }
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
  const signOut = async () => {
    setLeaving({ busy: true })
    logging = false
    let revoked = null
    try {
      // A bunker is asked to drop this browser's grant; null means there was no grant to drop (extension).
      revoked = signer?.revoke ? await signer.revoke() : (signer?.close?.(), null)
      const { failed } = await forgetThisBrowser({ vault, pubkey: session.pubkey })
      if (failed.length || revoked === false) setLeaving({ failed, revoked })
      else restart()
    } catch (e) {
      setLeaving({ failed: [], revoked, error: String(e?.message ?? e) })
    }
  }
  const retryWipe = async () => {
    setLeaving(l => ({ ...l, busy: true, error: "" }))
    try {
      const { failed } = await forgetThisBrowser({ vault, pubkey: session.pubkey })
      setLeaving(l => ({ ...l, busy: false, failed }))
    } catch (e) {
      setLeaving(l => ({ ...l, busy: false, error: String(e?.message ?? e) }))
    }
  }

  if (leaving) return <SignOutScreen {...leaving} onRetry={retryWipe} onDone={restart} />
  if (!session) return <SignInScreen onSignedIn={onSignedIn} />
  if (error) return <main class="screen"><p class="error">Your relay didn't start: {error}</p><button onClick={() => location.reload()}>Try again</button></main>
  if (!vault || !account) return <main class="splash"><img src="./icon.svg" alt="" /><p class="muted">Starting your relay…</p></main>

  // After a follow or unfollow: the new list is in Haven's outbox, so read the account back and the feed follows it.
  const reloadAccount = async () => setAccount({ ...(await readAccount(vault, session.pubkey)), loaded: true })
  const ctx = { vault, session, signer, account, signOut, reloadAccount }
  setActionContext(ctx)
  const other = route === "profile" && arg && arg !== session.pubkey // someone else's profile, reached from Search
  return (
    <div class="app">
      {route === "feed" && <FeedScreen ctx={ctx} />}
      {route === "compose" && <ComposeScreen ctx={ctx} />}
      {route === "profile" && (other ? <PersonScreen key={arg} ctx={ctx} pubkey={arg} /> : <ProfileScreen ctx={ctx} />)}
      {route === "search" && <SearchScreen ctx={ctx} onProfile={pk => { location.hash = `#/profile/${pk}` }} />}
      {route === "notifications" && <NotificationsScreen ctx={ctx} />}
      {route === "thread" && <ThreadScreen key={arg} ctx={ctx} id={arg} />}
      {route === "messages" && <MessagesScreen ctx={ctx} />}
      {route === "dm" && <ConversationScreen key={arg} ctx={ctx} peer={arg} />}
      {route === "vault" && <VaultScreen ctx={ctx} />}
      {route === "settings" && <SettingsScreen key={arg} ctx={ctx} page={arg} />}
      {route === "accounts" && <AccountsScreen ctx={ctx} />}
      <div hidden={route !== "relay"}><RelayScreen ctx={ctx} log={log} /></div>
      {(route === "feed" || route === "profile" && !other) && <PostButton />}
      <TabBar route={other ? "search" : route === "dm" ? "messages" : route} pubkey={session.pubkey} />
      <AuthPrompt />
    </div>
  )
}

// Sign-out says plainly what it couldn't do: a store still open (another tab) or a bunker grant still live.
function SignOutScreen({ busy, failed = [], revoked, error, onRetry, onDone }) {
  if (busy && !failed.length) return <main class="splash"><img src="./icon.svg" alt="" /><p class="muted">Signing out…</p></main>
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

if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(e => log("sw-error", { err: String(e) }))
navigator.storage?.persist?.().then(granted => log("persist", { granted }))
render(<App />, document.getElementById("app"))
