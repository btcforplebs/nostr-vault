// Our own napplets, built into the app (trusted like the screens they replace: first-party grant, policy.js).
// P1 carries the P0 sample only; the Emoji napplet (P2) is the first real one.
import noteDrafts from "../../napplets/note-drafts/index.html?raw"

export const FIRST_PARTY = [
  { dTag: "nv-note-drafts", title: "Note Drafts", html: noteDrafts },
]
