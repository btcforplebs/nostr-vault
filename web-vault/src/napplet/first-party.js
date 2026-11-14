// Our own napplets, built into the app (trusted like the screens they replace: first-party grant, policy.js). The list
// is first-party-list.js (also what tools/napplet-release.mjs builds); this adds each one's bytes.
import noteDrafts from "../../napplets/note-drafts/index.html?raw"
import emoji from "../../napplets/emoji/index.html?raw"
import reader from "../../napplets/reader/index.html?raw"
import compose from "../../napplets/compose/index.html?raw"
import media from "../../napplets/media/index.html?raw"
import wot from "../../napplets/wot/index.html?raw"
import messages from "../../napplets/messages/index.html?raw"
import wotPure from "../net/wot-pure.js?raw"
import wotGlobe from "../net/wot-globe.js?raw"
import { injectWot } from "./wot-inject.js"
import { FIRST_PARTY_LIST } from "./first-party-list.js"

export { EMOJI_DTAG, READER_DTAG, COMPOSE_DTAG, MEDIA_DTAG, WOT_DTAG, MESSAGES_DTAG } from "./first-party-list.js"

const FILES = { "note-drafts": noteDrafts, emoji, reader, compose, media, wot, messages }
export const FIRST_PARTY = FIRST_PARTY_LIST.map(n => ({ ...n, html: n.maths ? injectWot(FILES[n.file], [wotPure, wotGlobe]) : FILES[n.file] }))
export const firstParty = dTag => FIRST_PARTY.find(n => n.dTag === dTag)

/** The ones the Apps pane lists: a pane napplet (pane: true) runs in its own screen, with the intents it needs. */
export const LISTED = FIRST_PARTY.filter(n => !n.pane)
