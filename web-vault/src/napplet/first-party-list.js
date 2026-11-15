// Our own napplets, as data (plan P8): what each is called, which file it is, the NAP domains it asks for, the intents
// it takes (napplet:<archetype>/<action>) and a line about it. Pure, so tools/napplet-release.mjs builds the publishable
// files from the same list the app runs (first-party.js adds the bytes). `maths`: carries the WoT maths (wot-inject.js).
// `pane`: runs in its own screen of the app, not in the Apps list. `widget`: a card of Your space (plan NV_WEB_ONE_PLAN.md
// step 4), drawn at these sizes (the manifest's ["surface","widget",...] tag); `card`: the Your space panel id it draws.
export const EMOJI_DTAG = "nv-emoji"
export const READER_DTAG = "nv-reader"
export const COMPOSE_DTAG = "nv-compose"
export const MEDIA_DTAG = "nv-media"
export const WOT_DTAG = "nv-wot"
export const MESSAGES_DTAG = "nv-messages"
export const LIVE_NOW_DTAG = "nv-live-now"
export const ON_THIS_DAY_DTAG = "nv-on-this-day"
export const LIVE_VAULT_DTAG = "nv-live-vault"
export const WOT_MINI_DTAG = "nv-wot-mini"
export const MESSAGES_PEEK_DTAG = "nv-messages-peek"
export const MY_DEVICES_DTAG = "nv-my-devices"

export const FIRST_PARTY_LIST = [
  { dTag: EMOJI_DTAG, title: "Emoji", file: "emoji", domains: ["identity", "relay", "resource", "storage", "inc", "intent", "theme"], intents: ["emoji/pick"],
    summary: "Unicode emoji and your custom sets (NIP-30), picked into whatever asked." },
  // Plan P4: Feed + Thread + Profile, and Compose on its own (opened by the Reader's intents, ReaderPane.jsx).
  { dTag: READER_DTAG, title: "Reader", file: "reader", pane: true, domains: ["identity", "outbox", "resource", "intent", "inc", "theme"], intents: ["note/open", "profile/open", "feed/open"],
    summary: "Your follows' notes, threads and profiles. Likes; replies hand off to Compose." },
  { dTag: COMPOSE_DTAG, title: "Compose", file: "compose", pane: true, domains: ["identity", "outbox", "storage", "upload", "intent", "inc", "theme"], intents: ["compose/new", "compose/reply", "compose/quote"],
    summary: "Write a note, a reply (NIP-10) or a quote, with photos, and a draft kept until it's sent." },
  // Plan P5: Vault › Media (MediaPane.jsx): your media servers' files through NAP-BLOSSOM, bytes through resource.
  { dTag: MEDIA_DTAG, title: "Media", file: "media", pane: true, domains: ["identity", "blossom", "resource", "upload", "storage", "intent", "theme"], intents: ["media/open"],
    summary: "The files on your Blossom servers: filter, play, copy to missing servers, delete, upload." },
  // Plan P6: the WoT globe (WotPane.jsx). The shell computes the web (decision 6); the napplet draws it with the app's
  // own maths, put in at build (wot-inject.js).
  { dTag: WOT_DTAG, title: "Web of Trust", file: "wot", maths: true, pane: true, domains: ["resource", "intent", "theme"], intents: ["wot/show"],
    summary: "Your web of trust as a globe, drawn from what the shell computes." },
  // Plan P7: Messages (MessagesPane.jsx) over NAP-DM; keys, decryption and sealing stay in the shell (dm-dispatch.js).
  { dTag: MESSAGES_DTAG, title: "Messages", file: "messages", pane: true, domains: ["dm", "resource", "intent", "theme"], intents: ["dm/open", "dm/refresh"],
    summary: "Your direct messages, through the shell's NAP-DM: it holds the keys, this only sees text." },
  // One plan step 4: today's Your space cards as cards (widgets). The shell answers what each draws (widget-answers.js)
  // through shell-answered intents, so the rules stay the panels' own; the card's header is the shell's.
  { dTag: LIVE_NOW_DTAG, title: "Live now", file: "live-now", pane: true, widget: ["S", "M", "L"], card: "live-now", domains: ["resource", "intent", "inc", "theme"], intents: [],
    summary: "Streams from people you follow that are on air." },
  { dTag: ON_THIS_DAY_DTAG, title: "On this day", file: "on-this-day", pane: true, widget: ["S", "M", "L"], card: "on-this-day", domains: ["intent", "inc", "theme"], intents: [],
    summary: "Your own notes from this date one and two years ago, read from your vault." },
  { dTag: LIVE_VAULT_DTAG, title: "Live Vault", file: "live-vault", pane: true, widget: ["S", "M", "L"], card: "live-vault", domains: ["resource", "intent", "inc", "theme"], intents: [],
    summary: "Your Vault list's newest lines: likes, replies, zaps and follows as they come in." },
  { dTag: WOT_MINI_DTAG, title: "Web of Trust mini", file: "wot-mini", pane: true, widget: ["S", "M", "L"], card: "wot-mini", domains: ["resource", "intent", "inc", "theme"], intents: [],
    summary: "A small globe of your web, how many people are in it, and who is new in it." },
  { dTag: MESSAGES_PEEK_DTAG, title: "Messages peek", file: "messages-peek", pane: true, widget: ["S", "M", "L"], card: "messages", domains: ["resource", "intent", "inc", "theme"], intents: [],
    summary: "Your chats, unread first, each with its last line. The shell reads them; this card sees names and last lines only." },
  { dTag: MY_DEVICES_DTAG, title: "My devices", file: "my-devices", pane: true, widget: ["S", "M", "L"], card: "my-devices", domains: ["intent", "inc", "theme"], intents: [],
    summary: "Which of your own devices are on the mesh, and when each one last was." },
  { dTag: "nv-note-drafts", title: "Note Drafts", file: "note-drafts", domains: ["identity", "storage", "outbox", "theme"], intents: [], sample: true,
    summary: "A sample: write a note, it saves as you type." },
]
