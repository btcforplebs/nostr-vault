// The words the consent and ask sheets use (GrantSheet.jsx). Pure, so the copy is tested with the rules.
import { npubEncode } from "nostr-tools/nip19"
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
  dm: "Read your direct messages, and ask to send them",
}
/** An outside napplet never sees the vault's private data (Logen, 2026-11-14): there is no switch for it. */
export const PUBLIC_ONLY = "public data only"
export const PUBLIC_WORDS = "It never sees your vault's private data: your DMs, inbox, mute list or files. It reads public notes from people in your web of trust, through your vault."
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
// Every kind shows its tags (a named kind's hidden p/e tags too), and an addressable kind says it replaces the post
// with the same d tag (step 12 safety review: a kind 30023 could silently replace one of your articles).
const withTags = (kind, tags, text) => {
  const named = KIND_NAMES[kind] && !(tags ?? []).some(t => Array.isArray(t) && t[0])
  const d = kind >= 30000 && kind < 40000 ? (tags ?? []).find(t => Array.isArray(t) && t[0] === "d")?.[1] : undefined
  const replaces = d !== undefined ? `This replaces your earlier one with the same name ("${d.slice(0, 60)}"), if you have one.` : ""
  return [text, named ? "" : tagSummary(tags), replaces].filter(Boolean).join("\n\n")
}
/** The post's words for the ask, cut at 280 characters with a line saying how much more there is (step 12 review). */
export const previewOf = content => {
  const all = String(content ?? "")
  return all.length > 280 ? `${all.slice(0, 280)}… (${all.length - 280} more characters)` : all
}

/** One ask on screen at a time: a napplet's second ask while one is open is refused, so it can't swap the post shown
 *  under the user's finger (step 12 safety review). `show({ words, resolve })` puts the dialog up. */
export function oneAskAtATime(show) {
  let open = false
  return words => {
    if (open) return Promise.resolve(false)
    open = true
    return new Promise(resolve => show({ words, resolve: yes => { open = false; resolve(yes) } }))
  }
}

/** The ask sheet's question for one request -> { title, body, yes, no }. */
export function askWords(what, napplet, detail = {}) {
  const who = napplet?.title || napplet?.dTag || "This napplet"
  const preview = previewOf(detail.content)
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
  if (what === "dm-send") {
    // A profile name is the stranger's own choice (anyone can be "Mom"), so the key always shows beside it.
    const to = String(detail.to ?? "")
    let npub = to; try { npub = npubEncode(to) } catch {}
    const key = `${npub.slice(0, 16)}…`
    const text = String(detail.content ?? "")
    const more = text.length > 500 ? `\n\n… and ${text.length - 500} more characters` : ""
    return { title: `${who} wants to send a direct message as you`, body: `To ${detail.name ? `${detail.name} (${key})` : key}:\n\n${text.slice(0, 500)}${more}`, yes: "Send", no: "Don't send" }
  }
  if (what === "notify") return { title: `${who} wants to show notifications`, body: "Asked once. You can take it back by removing the napplet.", yes: "Allow", no: "Don't allow" }
  return { title: `${who} asks: ${what}`, body: "", yes: "Allow", no: "Don't allow" }
}
