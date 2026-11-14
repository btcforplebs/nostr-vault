// The words the consent and ask sheets use (NappletShell.jsx). Pure, so the copy is tested with the rules.
export const DOMAIN_WORDS = {
  identity: "See your public key, profile, follows and relays",
  theme: "Use Nostr Vault's colours",
  storage: "Keep its own settings in this browser",
  outbox: "Read notes, and ask to post as you",
  relay: "Read notes, and send notes already signed",
  resource: "Load pictures and files from the web",
  upload: "Ask to upload files to your media servers",
  intent: "Hand things to other napplets",
  inc: "Talk to other open napplets",
  notify: "Ask to show notifications",
}
export const PRIVATE_WORDS = {
  label: "Your vault's private data",
  help: "Your saved feed, inbox and DMs, your mute list and the vault's files. Off: it reads public relays only.",
}
export const domainWord = d => DOMAIN_WORDS[d] ?? d

const KIND_NAMES = { 1: "a note", 6: "a repost", 7: "a reaction", 16: "a repost", 1111: "a comment", 30023: "an article", 9802: "a highlight" }
export const kindName = k => KIND_NAMES[k] ?? `a kind ${k} event`

/** The ask sheet's question for one request -> { title, body, yes, no }. */
export function askWords(what, napplet, detail = {}) {
  const who = napplet?.title || napplet?.dTag || "This napplet"
  const preview = String(detail.content ?? "").slice(0, 280)
  if (what === "publish") return { title: `${who} wants to post ${kindName(detail.kind)} as you`, body: preview, yes: "Post", no: "Don't post" }
  if (what === "relay-publish") return { title: `${who} wants to send ${kindName(detail.kind)}`, body: preview, yes: "Send", no: "Don't send" }
  if (what === "upload") return { title: `${who} wants to upload a file`, body: `${detail.filename || "A file"} · ${(detail.size / 1e6).toFixed(1)} MB · ${detail.mime || "unknown type"}. It goes to your media servers.`, yes: "Upload", no: "Don't upload" }
  if (what === "notify") return { title: `${who} wants to show notifications`, body: "Asked once. You can take it back by removing the napplet.", yes: "Allow", no: "Don't allow" }
  return { title: `${who} asks: ${what}`, body: "", yes: "Allow", no: "Don't allow" }
}
