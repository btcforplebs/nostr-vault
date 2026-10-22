// A shared post, opened by someone who isn't signed in: the thread as the app draws it, read from public relays into
// memory, its photos loading over the FIPS mesh from each note's own author's vaults. A bar offers sign-in; signing
// in keeps the address, so the app opens on the same post. Anything other than a post shows the sign-in screen.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { ThreadScreen } from "../screens/ThreadScreen.jsx"
import { SignInScreen } from "../screens/SignInScreen.jsx"
import { setActionContext } from "../net/actions.js"
import { setQuoteSource } from "../net/quotes.js"
import { setMeshPeople, fipsMedia } from "../net/fips-media.js"
import { guestContext, guestRelays, guestTarget } from "./guest.js"
import { guestPostDeleted } from "./deleted.js"
import { SkeletonRows } from "../components/FeedExtras.jsx"
import "../styles/guest.css"

/** `bootHash`: the address the page opened with, before the desktop layout rewrote it (it carries the link's relay
 *  hints). `onSignedIn`: main.jsx's, which saves the session and starts the app. */
export function GuestApp({ bootHash, onSignedIn }) {
  const [hash, setHash] = useState(location.hash)
  const [signingIn, setSigningIn] = useState(false)
  const ctx = useMemo(() => guestContext(guestRelays(bootHash)), [])
  useEffect(() => {
    setActionContext(ctx)
    setQuoteSource({ vault: ctx.vault, relays: ctx.account.relays.read })
    const f = () => setHash(location.hash)
    addEventListener("hashchange", f)
    return () => removeEventListener("hashchange", f)
  }, [])
  const id = guestTarget(hash)
  const lastId = useRef(null) // a profile or hashtag tapped from the post: sign-in, with a way back to the post
  if (id) lastId.current = id

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

  if (signingIn || !id) {
    return (
      <>
        {lastId.current && <div class="guest-back"><button class="small" onClick={() => id ? setSigningIn(false) : history.back()}>Back to the post</button></div>}
        <SignInScreen onSignedIn={onSignedIn} />
      </>
    )
  }
  return (
    <div class="app guest-app">
      {checked?.id !== id ? <main class="screen"><SkeletonRows count={2} label="Opening the post…" /></main>
        : checked.deleted ? <main class="screen"><p class="empty">This post was deleted by its author.</p></main>
        : <ThreadScreen key={id} ctx={ctx} id={id} onAuthors={onAuthors} />}
      <div class="guest-bar" role="region" aria-label="Guest">
        <span class="guest-note">Viewing as a guest</span>
        <a class="button small" href="/">Get the app</a>
        <button class="small primary" onClick={() => setSigningIn(true)}>Sign in</button>
      </div>
    </div>
  )
}
