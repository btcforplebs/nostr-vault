// Sign-in with no Nostr extension in this browser: the one to install for it (signer/nip07.js extensionHelp; on iPhone and
// iPad, Nostr Build Shack then Nostash), each drawn as an install card with the extension's own icon and a store badge, and a way to look again once it's in. Shown by
// SignInOptions when "Sign in with extension" finds nothing. On Android, where no extension runs, the note's signer app
// (Amber) gets the same card, linked to its store page. The icons are copies in public/ext/, never hotlinked.
import { Fragment } from "preact"
import { useState } from "preact/hooks"
import { findExtension, extensionHelp } from "../signer/nip07.js"

const ICON = { Sidecar: "./ext/sidecar.png", Nostash: "./ext/nostash.png", "Nostr Build Shack": "./ext/nostr-build-shack.png", Amber: "./ext/amber.png" }
const LINE = { "Nostr Build Shack": () => "Keeps your Nostr key in this device's keychain and signs in Safari for sites like this one." }
const BADGE = {
  "Chrome Web Store": { glyph: "./ext/chrome-web-store.png", small: "Chrome Web Store", big: browser => `Add to ${browser}` },
  "Firefox Add-ons": { glyph: "./ext/firefox.svg", small: "Firefox Add-ons", big: () => "Add to Firefox" },
  "App Store": { glyph: "./ext/apple.svg", small: "Get on the", big: () => "App Store" },
  "Mac App Store": { glyph: "./ext/apple.svg", small: "Get on the", big: () => "Mac App Store" },
}

/** What the install card shows for extensionHelp's answer: the extension's icon, its one line, and the store badge. */
export function installCard(help) {
  const badge = BADGE[help.store]
  return {
    icon: ICON[help.name],
    line: LINE[help.name]?.() ?? `Keeps your Nostr key in ${help.browser} and signs for sites like this one.`,
    badge: { glyph: badge.glyph, small: badge.small, big: badge.big(help.browser) },
  }
}

/** The note with its signer app's name linked to the app's store page. */
export function noteWithSigner({ note, signer }) {
  const at = signer ? note.indexOf(signer.name) : -1
  if (at < 0) return note
  return <Fragment>{note.slice(0, at)}<a href={signer.url} target="_blank" rel="noopener noreferrer">{signer.name}</a>{note.slice(at + signer.name.length)}</Fragment>
}

/** The note's signer app as an install card: its icon and name, linked to its store page. */
export function SignerCard({ signer }) {
  return (
    <a class="ext-card" href={signer.url} target="_blank" rel="noopener noreferrer">
      <img class="ext-icon" src={ICON[signer.name]} alt="" width="48" height="48" />
      <div class="ext-about">
        <h2>{signer.name}</h2>
        <p>Signs for Nostr apps on your phone. Get it on {signer.store}, then copy its bunker link.</p>
      </div>
    </a>
  )
}

/** No extension in this browser: the one to install for it, and a way to look again once it's in. An extension can
 *  appear late, and one installed while the page is open often reaches it only after a reload. */
export function GetExtension({ disabled, onFound }) {
  const help = extensionHelp(navigator.userAgent, { brave: !!navigator.brave, touch: navigator.maxTouchPoints })
  const [looking, setLooking] = useState(false)
  const [missed, setMissed] = useState(false)
  const retry = async () => {
    setLooking(true); setMissed(false)
    const ext = await findExtension(3000)
    setLooking(false)
    if (ext) onFound(); else setMissed(true)
  }
  if (help.note) return <div class="get-extension"><h2>No Nostr extension in {help.browser}</h2><p>{noteWithSigner(help)}</p>{help.signer && <SignerCard signer={help.signer} />}</div>
  const apps = [help, ...(help.more || []).map(app => ({ ...app, browser: help.browser }))]
  return (
    <div class="get-extension">
      {apps.map(app => {
        const card = installCard(app)
        return (
          <Fragment key={app.name}>
            <div class="ext-card">
              <img class="ext-icon" src={card.icon} alt="" width="48" height="48" />
              <div class="ext-about">
                <h2>{app.name}</h2>
                <p>{card.line}</p>
              </div>
            </div>
            <a class="store-badge" href={app.url} target="_blank" rel="noopener noreferrer">
              <img src={card.badge.glyph} alt="" width="26" height="26" />
              <span><small>{card.badge.small}</small><b>{card.badge.big}</b></span>
            </a>
            {app.after && <p class="small">{app.after}</p>}
          </Fragment>
        )
      })}
      <button disabled={disabled || looking} onClick={retry} aria-busy={looking || undefined}>{looking ? "Looking for the extension…" : "I installed it, try again"}</button>
      {missed && <p class="small">Still no extension here. If you just installed it, <a href="" onClick={e => { e.preventDefault(); location.reload() }}>reload this page</a> and sign in again.</p>}
    </div>
  )
}
