// Our own napplets, built into the app (trusted like the screens they replace: first-party grant, policy.js). Each one
// asks only for the domains it uses.
import noteDrafts from "../../napplets/note-drafts/index.html?raw"
import emoji from "../../napplets/emoji/index.html?raw"
import reader from "../../napplets/reader/index.html?raw"
import compose from "../../napplets/compose/index.html?raw"
import media from "../../napplets/media/index.html?raw"

export const EMOJI_DTAG = "nv-emoji"
export const READER_DTAG = "nv-reader"
export const COMPOSE_DTAG = "nv-compose"
export const MEDIA_DTAG = "nv-media"
export const FIRST_PARTY = [
  { dTag: EMOJI_DTAG, title: "Emoji", html: emoji, domains: ["identity", "relay", "resource", "storage", "inc", "intent"] },
  // Plan P4: Feed + Thread + Profile, and Compose on its own (opened by the Reader's intents, ReaderPane.jsx).
  { dTag: READER_DTAG, title: "Reader", html: reader, pane: true, domains: ["identity", "outbox", "resource", "intent", "inc", "theme"] },
  { dTag: COMPOSE_DTAG, title: "Compose", html: compose, pane: true, domains: ["identity", "outbox", "storage", "intent", "inc", "theme"] },
  // Plan P5: Vault › Media (MediaPane.jsx): your media servers' files through NAP-BLOSSOM, bytes through resource.
  { dTag: MEDIA_DTAG, title: "Media", html: media, pane: true, domains: ["identity", "blossom", "resource", "upload", "storage", "intent", "theme"] },
  { dTag: "nv-note-drafts", title: "Note Drafts", html: noteDrafts },
]
export const firstParty = dTag => FIRST_PARTY.find(n => n.dTag === dTag)

/** The ones the Apps pane lists: a pane napplet (pane: true) runs in its own screen, with the intents it needs. */
export const LISTED = FIRST_PARTY.filter(n => !n.pane)
