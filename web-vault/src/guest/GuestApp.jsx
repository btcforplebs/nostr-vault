// Someone who isn't signed in: the welcome screen, and from it (or a shared link) a post or a person as the app draws
// them, read from public relays into memory. A post's photos load over the FIPS mesh from each note's own author's
// vaults. A bar offers sign-in; signing in keeps the address, so the app opens on the same post. Any other address
// shows the welcome screen.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { ThreadScreen } from "../screens/ThreadScreen.jsx"
import { PersonScreen } from "../screens/PersonScreen.jsx"
import { SignInScreen } from "../screens/SignInScreen.jsx"
import { WelcomeScreen } from "../screens/WelcomeScreen.jsx"
import { CreateAccount } from "../screens/CreateAccount.jsx"
import { learn } from "../shell.js"
import { setActionContext } from "../net/actions.js"
import { setQuoteSource } from "../net/quotes.js"
import { setMeshPeople, fipsMedia } from "../net/fips-media.js"
import { guestContext, guestPerson, guestRelays, guestTarget } from "./guest.js"
import { guestPostDeleted } from "./deleted.js"
import { SkeletonRows } from "../components/FeedExtras.jsx"
import "../styles/guest.css"

/** `bootHash`: the address the page opened with, before the desktop layout rewrote it (it carries the link's relay
 *  hints). `onSignedIn`: main.jsx's, which saves the session and starts the app. */
export function GuestApp({ bootHash, onSignedIn }) {
  const [hash, setHash] = useState(location.hash)
  const [signingIn, setSigningIn] = useState(false)
  const [creating, setCreating] = useState(false)
  const ctx = useMemo(() => guestContext(guestRelays(bootHash)), [])
  useEffect(() => {
    setActionContext(ctx)
    setQuoteSource({ vault: ctx.vault, relays: ctx.account.relays.read })
    const f = () => setHash(location.hash)
    addEventListener("hashchange", f)
    return () => removeEventListener("hashchange", f)
  }, [])
  const id = guestTarget(hash)
  const person = id ? null : guestPerson(hash)
  const lastId = useRef(null) // a hashtag or Message tapped from a post or a person: sign-in, with a way back
  if (id || person) lastId.current = id || person

  // Nothing of the post is drawn until we know its author didn't delete it: its photos could otherwise still come off
  // their vault over the mesh. { id, deleted } once asked for this id.
  const [checked, setChecked] = useState(null)
  useEffect(() => {
    if (!id) return
    let live = true
    guestPostDeleted(id, ctx.account.relays.read).then(deleted => { if (live) setChecked({ id, deleted }) }, () => { if (live) setChecked({ id, deleted: false }) })
    return () => { live = false }
  }, [id])

  // Whose photos may load over the mesh: everyone who wrote in this thread, each from their own vaults (fips-media.js
  // asks only the vaults the photo's own author lists). The reader starts as the thread opens.
  const onAuthors = authors => {
    setMeshPeople(undefined, authors)
    fipsMedia().warm(authors)
  }

  const viewing = id || person
  // Any other app address (Message, a hashtag, an old link) needs an account: sign-in, with a way back.
  const home = !hash || hash === "#" || hash === "#/"
  if (creating) return <CreateAccount onSignedIn={onSignedIn} onBack={() => setCreating(false)} />
  if (signingIn || (!viewing && !home)) {
    const back = signingIn ? () => setSigningIn(false) : lastId.current ? () => history.back() : () => { location.hash = "#/" }
    return (
      <>
        <div class="guest-back"><button class="small" onClick={back}>‹ Back</button></div>
        <SignInScreen onSignedIn={onSignedIn} />
      </>
    )
  }
  if (!viewing) return <WelcomeScreen onSignIn={() => setSigningIn(true)} onCreate={() => setCreating(true)} />
  return (
    <div class="app guest-app">
      {person ? <PersonScreen key={person} ctx={ctx} pubkey={person} />
        : checked?.id !== id ? <main class="screen"><SkeletonRows count={2} label="Opening the post…" /></main>
        : checked.deleted ? <main class="screen"><p class="empty">This post was deleted by its author.</p></main>
        : <ThreadScreen key={id} ctx={ctx} id={id} onAuthors={onAuthors} />}
      <div class="guest-bar" role="region" aria-label="Guest">
        <a class="button small guest-home" href="#/" aria-label="Home" title="Home">‹</a>
        <span class="guest-note">Viewing as a guest</span>
        <button class="small" onClick={() => learn("platforms")}>Get the app</button>
        <button class="small primary" onClick={() => setSigningIn(true)}>Sign in</button>
      </div>
    </div>
  )
}
