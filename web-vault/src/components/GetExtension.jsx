// Sign-in with no Nostr extension in this browser: the one to install for it (signer/nip07.js extensionHelp), drawn as an
// install card with the extension's own icon and a store badge, and a way to look again once it's in. Shown by
// SignInOptions when "Sign in with extension" finds nothing. The icons are copies in public/ext/, never hotlinked.
import { useState } from "preact/hooks"
import { findExtension, extensionHelp } from "../signer/nip07.js"

const ICON = { Sidecar: "./ext/sidecar.png", Nostash: "./ext/nostash.png" }
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
    line: `Keeps your Nostr key in ${help.browser} and signs for sites like this one.`,
    badge: { glyph: badge.glyph, small: badge.small, big: badge.big(help.browser) },
  }
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
  if (help.note) return <div class="get-extension"><h2>No Nostr extension in {help.browser}</h2><p>{help.note}</p></div>
  const card = installCard(help)
  return (
    <div class="get-extension">
      <div class="ext-card">
        <img class="ext-icon" src={card.icon} alt="" width="48" height="48" />
        <div class="ext-about">
          <h2>{help.name}</h2>
          <p>{card.line}</p>
        </div>
      </div>
      <a class="store-badge" href={help.url} target="_blank" rel="noopener noreferrer">
        <img src={card.badge.glyph} alt="" width="26" height="26" />
        <span><small>{card.badge.small}</small><b>{card.badge.big}</b></span>
      </a>
      {help.after && <p class="small">{help.after}</p>}
      <button disabled={disabled || looking} onClick={retry} aria-busy={looking || undefined}>{looking ? "Looking for the extension…" : "I installed it, try again"}</button>
      {missed && <p class="small">Still no extension here. If you just installed it, <a href="" onClick={e => { e.preventDefault(); location.reload() }}>reload this page</a> and sign in again.</p>}
    </div>
  )
}
