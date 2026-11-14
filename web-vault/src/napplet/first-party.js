// Our own napplets, built into the app (trusted like the screens they replace: first-party grant, policy.js). Each one
// asks only for the domains it uses.
import noteDrafts from "../../napplets/note-drafts/index.html?raw"
import emoji from "../../napplets/emoji/index.html?raw"

export const EMOJI_DTAG = "nv-emoji"
export const FIRST_PARTY = [
  { dTag: EMOJI_DTAG, title: "Emoji", html: emoji, domains: ["identity", "relay", "resource", "storage", "inc", "intent"] },
  { dTag: "nv-note-drafts", title: "Note Drafts", html: noteDrafts },
]
export const firstParty = dTag => FIRST_PARTY.find(n => n.dTag === dTag)
