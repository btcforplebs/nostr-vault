// Our own napplets, built into the app (trusted like the screens they replace: first-party grant, policy.js). The list
// is first-party-list.js (also what tools/napplet-release.mjs builds); this adds each one's bytes.
import noteDrafts from "../../napplets/note-drafts/index.html?raw"
import emoji from "../../napplets/emoji/index.html?raw"
import reader from "../../napplets/reader/index.html?raw"
import compose from "../../napplets/compose/index.html?raw"
import media from "../../napplets/media/index.html?raw"
import wot from "../../napplets/wot/index.html?raw"
import messages from "../../napplets/messages/index.html?raw"
import liveNow from "../../napplets/live-now/index.html?raw"
import onThisDay from "../../napplets/on-this-day/index.html?raw"
import liveVault from "../../napplets/live-vault/index.html?raw"
import wotMini from "../../napplets/wot-mini/index.html?raw"
import messagesPeek from "../../napplets/messages-peek/index.html?raw"
import myDevices from "../../napplets/my-devices/index.html?raw"
import wotPure from "../net/wot-pure.js?raw"
import wotGlobe from "../net/wot-globe.js?raw"
import themeClient from "./theme-client.js?raw"
import { injectWot } from "./wot-inject.js"
import { injectTheme } from "./theme-inject.js"
import { FIRST_PARTY_LIST } from "./first-party-list.js"

export { EMOJI_DTAG, READER_DTAG, COMPOSE_DTAG, MEDIA_DTAG, WOT_DTAG, MESSAGES_DTAG, LIVE_NOW_DTAG, ON_THIS_DAY_DTAG, LIVE_VAULT_DTAG, WOT_MINI_DTAG, MESSAGES_PEEK_DTAG, MY_DEVICES_DTAG } from "./first-party-list.js"

const FILES = { "note-drafts": noteDrafts, emoji, reader, compose, media, wot, messages, "live-now": liveNow, "on-this-day": onThisDay, "live-vault": liveVault, "wot-mini": wotMini, "messages-peek": messagesPeek, "my-devices": myDevices }
const withMaths = n => (n.maths ? injectWot(FILES[n.file], [wotPure, wotGlobe]) : FILES[n.file])
export const FIRST_PARTY = FIRST_PARTY_LIST.map(n => ({ ...n, html: injectTheme(withMaths(n), themeClient) }))
export const firstParty = dTag => FIRST_PARTY.find(n => n.dTag === dTag)
/** The widget napplet that draws Your space panel `id`, or undefined. */
export const widgetFor = id => FIRST_PARTY.find(n => n.widget && n.card === id)

/** The ones the Apps pane lists: a pane napplet (pane: true) runs in its own screen, with the intents it needs. */
export const LISTED = FIRST_PARTY.filter(n => !n.pane)
