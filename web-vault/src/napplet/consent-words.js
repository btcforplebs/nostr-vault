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
  blossom: "See the files on your media servers, and ask to copy or delete them",
}
export const PRIVATE_WORDS = {
  label: "Your vault's private data",
  help: "Your saved feed, inbox and DMs, your mute list and the vault's files. It can send what it sees to whoever made it. Off: it reads public relays only.",
}
export const domainWord = d => DOMAIN_WORDS[d] ?? d
const sizeWords = n => (n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1e3))} KB`)
const hostOf = u => { try { return new URL(u).host } catch { return String(u ?? "") } }

const KIND_NAMES = { 1: "a note", 6: "a repost", 7: "a reaction", 16: "a repost", 1111: "a comment", 30023: "an article", 9802: "a highlight" }
export const kindName = k => KIND_NAMES[k] ?? `a kind ${k} event`

/** What a kind we don't name carries, so the sheet never shows only its text: "Tags: 2 e (events), 1 p (people)". */
const TAG_NAMES = { e: "events", p: "people", a: "addresses", t: "topics", k: "kinds" }
export function tagSummary(tags = []) {
  const counts = new Map()
  for (const t of tags) if (Array.isArray(t) && t[0]) counts.set(t[0], (counts.get(t[0]) ?? 0) + 1)
  if (!counts.size) return "No tags."
  return `Tags: ${[...counts].map(([n, c]) => `${c} ${n}${TAG_NAMES[n] ? ` (${TAG_NAMES[n]})` : ""}`).join(", ")}.`
}
const withTags = (kind, tags, text) => (KIND_NAMES[kind] ? text : [text, tagSummary(tags)].filter(Boolean).join("\n\n"))

/** The ask sheet's question for one request -> { title, body, yes, no }. */
export function askWords(what, napplet, detail = {}) {
  const who = napplet?.title || napplet?.dTag || "This napplet"
  const preview = String(detail.content ?? "").slice(0, 280)
  if (what === "publish" && detail.kind === 5) {
    const n = (detail.tags ?? []).filter(t => (t[0] === "e" || t[0] === "a") && t[1]).length
    return { title: `${who} wants to delete ${n} of your posts`, body: [preview && `Reason: ${preview}`, "Relays that keep them are asked to drop them. This can't be undone."].filter(Boolean).join("\n\n"), yes: "Delete", no: "Don't delete" }
  }
  if (what === "publish") return { title: `${who} wants to post ${kindName(detail.kind)} as you`, body: withTags(detail.kind, detail.tags, preview), yes: "Post", no: "Don't post" }
  if (what === "relay-publish") return { title: `${who} wants to send ${kindName(detail.kind)}`, body: withTags(detail.kind, detail.tags, preview), yes: "Send", no: "Don't send" }
  if (what === "upload") return { title: `${who} wants to upload a file`, body: `${detail.filename || "A file"} · ${(detail.size / 1e6).toFixed(1)} MB · ${detail.mime || "unknown type"}. It goes to your media servers.`, yes: "Upload", no: "Don't upload" }
  if (what === "blossom-delete") {
    const facts = [detail.type || "unknown type", Number.isFinite(detail.size) && detail.size > 0 ? sizeWords(detail.size) : null].filter(Boolean).join(" · ")
    const image = /^image\//i.test(detail.type ?? "") || (!detail.type && /^https:\/\//i.test(detail.url ?? "")) ? detail.url : null
    return { title: `${who} wants to delete a file from ${hostOf(detail.server) || "your media servers"}`, body: `File ${String(detail.sha256 ?? "").slice(0, 12)}… · ${facts}\n\nOnly that server is asked to drop it, and a vault of yours keeps its copy. This can't be undone.`, image, yes: "Delete", no: "Keep it" }
  }
  if (what === "blossom-mirror") return { title: `${who} wants to copy a file to ${hostOf(detail.server)}`, body: `File ${String(detail.sha256 ?? "").slice(0, 12)}…\n\nThat server fetches it from where it is now.`, yes: "Copy", no: "Don't copy" }
  if (what === "notify") return { title: `${who} wants to show notifications`, body: "Asked once. You can take it back by removing the napplet.", yes: "Allow", no: "Don't allow" }
  return { title: `${who} asks: ${what}`, body: "", yes: "Allow", no: "Don't allow" }
}
