// Nostr Vault on the web. Boot: sign-in (NIP-07 / NIP-46) -> the in-page Haven owned by that npub -> the app.
// Every screen reads from Haven; the network only fills Haven. See PLANS/NV_WEB_CLIENT.md.
import { render } from "preact"
import { useEffect, useState } from "preact/hooks"
import { loadSession, saveSession, clearSession } from "./src/session.js"
import { signerFor } from "./src/signer/index.js"
import { startVault } from "./src/haven/vault.js"
import { readAccount, refreshAccount } from "./src/net/sync.js"
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./src/net/pool.js"
import { putProfile } from "./src/net/profiles.js"
import { SignInScreen } from "./src/screens/SignInScreen.jsx"
import { FeedScreen } from "./src/screens/FeedScreen.jsx"
import { ComposeScreen } from "./src/screens/ComposeScreen.jsx"
import { ProfileScreen } from "./src/screens/ProfileScreen.jsx"
import { RelayScreen } from "./src/screens/RelayScreen.jsx"
import { TabBar } from "./src/components/TabBar.jsx"
import "./src/styles/app.css"

const ROUTES = ["feed", "compose", "profile", "relay"]
const routeOf = () => { const r = location.hash.replace(/^#\/?/, "").split(/[/?]/)[0]; return ROUTES.includes(r) ? r : "feed" }

// Kept in localStorage so a phone run can be read back over CDP; nothing leaves the device.
const logLines = JSON.parse(localStorage.getItem("nv-log") || "[]")
function log(type, data = {}) {
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
  const [route, setRoute] = useState(routeOf)

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
      setAccount({ ...local, loaded: !!local.contacts })
      if (!navigator.onLine) return
      const fresh = await refreshAccount(v, session.pubkey, uniq([...local.relays.read, ...local.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]))
      putProfile(fresh.profileEvent)
      if (live) setAccount({ ...fresh, loaded: true })
      log("account", { follows: fresh.follows.length, cachedFollows: local.follows.length })
    })().catch(e => { log("boot-error", { err: String(e) }); setError(String(e?.message ?? e)) })
    return () => { live = false }
  }, [session?.pubkey])

  const onSignedIn = ({ signer, session }) => { saveSession(session); setSigner(signer); setSession(session); log("signed-in", { method: session.method }) }
  const signOut = () => { signer?.close?.(); clearSession(); log("signed-out"); location.replace(location.pathname) }

  if (!session) return <SignInScreen onSignedIn={onSignedIn} />
  if (error) return <main class="screen"><p class="error">Your relay didn't start: {error}</p><button onClick={() => location.reload()}>Try again</button></main>
  if (!vault || !account) return <main class="splash"><img src="./icon.svg" alt="" /><p class="muted">Starting your relay…</p></main>

  const ctx = { vault, session, signer, account, signOut }
  return (
    <div class="app">
      {route === "feed" && <FeedScreen ctx={ctx} />}
      {route === "compose" && <ComposeScreen ctx={ctx} />}
      {route === "profile" && <ProfileScreen ctx={ctx} />}
      <div hidden={route !== "relay"}><RelayScreen ctx={ctx} log={log} /></div>
      <TabBar route={route} />
    </div>
  )
}

if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(e => log("sw-error", { err: String(e) }))
navigator.storage?.persist?.().then(granted => log("persist", { granted }))
render(<App />, document.getElementById("app"))
