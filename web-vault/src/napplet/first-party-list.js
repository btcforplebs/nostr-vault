// Our own napplets, as data (plan P8): what each is called, which file it is, the NAP domains it asks for, the intents
// it takes (napplet:<archetype>/<action>) and a line about it. Pure, so tools/napplet-release.mjs builds the publishable
// files from the same list the app runs (first-party.js adds the bytes). `maths`: carries the WoT maths (wot-inject.js).
// `pane`: runs in its own screen of the app, not in the Apps list.
export const EMOJI_DTAG = "nv-emoji"
export const READER_DTAG = "nv-reader"
export const COMPOSE_DTAG = "nv-compose"
export const MEDIA_DTAG = "nv-media"
export const WOT_DTAG = "nv-wot"
export const MESSAGES_DTAG = "nv-messages"

export const FIRST_PARTY_LIST = [
  { dTag: EMOJI_DTAG, title: "Emoji", file: "emoji", domains: ["identity", "relay", "resource", "storage", "inc", "intent"], intents: ["emoji/pick"],
    summary: "Unicode emoji and your custom sets (NIP-30), picked into whatever asked." },
  // Plan P4: Feed + Thread + Profile, and Compose on its own (opened by the Reader's intents, ReaderPane.jsx).
  { dTag: READER_DTAG, title: "Reader", file: "reader", pane: true, domains: ["identity", "outbox", "resource", "intent", "inc", "theme"], intents: ["note/open", "profile/open", "feed/open"],
    summary: "Your follows' notes, threads and profiles. Likes; replies hand off to Compose." },
  { dTag: COMPOSE_DTAG, title: "Compose", file: "compose", pane: true, domains: ["identity", "outbox", "storage", "intent", "inc", "theme"], intents: ["compose/new", "compose/reply"],
    summary: "Write a note or a reply (NIP-10), with a draft kept until it's sent." },
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
  { dTag: "nv-note-drafts", title: "Note Drafts", file: "note-drafts", domains: ["identity", "storage", "outbox"], intents: [], sample: true,
    summary: "A sample: write a note, it saves as you type." },
]
