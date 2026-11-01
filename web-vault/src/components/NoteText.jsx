// Plain text with links, inline images and video, named @mentions and quoted notes.
// nostr:npub / nprofile -> the person's name, linking to their profile. nostr:nevent / note / naddr -> the quoted
// note as a card (QuotedNote). A quote inside a quoted note stays a short reference, so cards don't nest forever.
import { npubEncode } from "nostr-tools/nip19"
import { useEffect, useState } from "preact/hooks"
import { useProfile } from "./useProfile.js"
import { fetchProfiles } from "../net/profiles.js"
import { getQuote, onQuotes, parseRef, quoteSource } from "../net/quotes.js"
import { QuotedNote } from "./QuotedNote.jsx"
import { splitHashtags } from "../net/hashtags.js"
import { mediaType } from "../net/media.js"
import { meshHost } from "../net/fips-ref.js"
import { noteMedia } from "../net/note-media.js"
import { NoteMedia } from "./NoteMedia.jsx"
import { inlineMarks } from "../net/inline-md.js"
import { LinkCard } from "./LinkCard.jsx"
import { BlossomMedia } from "./BlossomMedia.jsx"
import { parseBlossomUri } from "../net/blossom-uri.js"
import { liveDrops, liveRefs, trimAroundLive } from "../net/live-note.js"

// A BUD-10 blossom:<sha256>.<ext>?… link is one token too, so its query never reads as text (BlossomMedia).
const TOKEN = /(https?:\/\/[^\s<>"]+|nostr:[a-z0-9]+|blossom:[0-9a-fA-F]{64}\.[A-Za-z0-9]{1,10}(?:\?[^\s<>"]*)?)/gi
const MAX_QUOTE_DEPTH = 1

/** `dm`: the text is a private message, so nothing in it reaches the network on its own: video links stay links
 *  (no preload), nostr:npub / nprofile stay short text (no profile fetch), and an image waits for a tap unless
 *  `images` says the sender is trusted (a follow, or you). Otherwise any stranger's DM would be a tracking pixel:
 *  opening it would tell their server your IP and when you read it.
 *  `memoryOnly`: a stranger's note (Global, Hashtag): quotes and @names it loads aren't written to Haven /feed.
 *  `tags`: the note's tags, for its NIP-92 imeta media. Outside a DM, with images on, the note's media (text links
 *  and imeta, noteMedia) go under the text as one picture or a carousel (NoteMedia) and their links leave the text,
 *  as iOS FeedNoteRow does. `author`: the note's pubkey, for a photo on the author's mesh vault (MediaImage). */
/*  `linkCards`: a feed card's links (not media, not nostr:) become up to three link cards under the text and leave it,
 *  as iOS LinkCards does. */
/*  `streams`: the kind 30311 events of the live streams the text embeds (live-note.js), filled in by LiveNoteText. */
export function NoteText(props) {
  const { content, tags, author, depth = 0, dm = false, memoryOnly = false, images = !dm, linkCards = false, streams } = props
  const lives = depth < MAX_QUOTE_DEPTH ? liveRefs(content) : []
  if (lives.length && !streams) return <LiveNoteText {...props} refs={lives} />
  let parts = String(content).split(TOKEN)
  // Punctuation that ends a sentence goes back into the text after the link.
  for (let i = 1; i < parts.length; i += 2) {
    const url = trimUrl(parts[i])
    parts[i + 1] = parts[i].slice(url.length) + parts[i + 1]
    parts[i] = url
  }
  // A live stream's card is the post: its playlist and picture links leave the text, and so do the blank lines.
  if (lives.length) {
    const drop = liveDrops(parts.filter((p, i) => i % 2 && /^https?:\/\//i.test(p)), true, streams)
    if (drop.size) parts = withoutLinks(parts, drop)
  }
  // blossom: links are drawn where they stand (BlossomMedia), never as an https picture in the carousel.
  const media = !dm && images ? noteMedia(parts.filter((p, i) => i % 2 && /^https?:\/\//i.test(p)), tags) : []
  if (media.length) parts = withoutLinks(parts, new Set(media.map(m => m.url)))
  const cards = linkCards && !dm ? cardLinks(parts) : []
  if (cards.length) parts = withoutLinks(parts, new Set(cards))
  if (lives.length) {
    const keys = new Set(lives.map(r => r.ref.toLowerCase()))
    parts = trimAroundLive(parts, s => /^nostr:/i.test(s) && keys.has(s.slice(6).toLowerCase()))
  }
  return (
    <div class="note-text">
      {parts.map((s, i) => {
        if (i % 2 === 0) return withMarks(s, i)
        if (s.startsWith("nostr:")) return nostrRef(s.slice(6), i, depth, dm, memoryOnly)
        if (/^blossom:/i.test(s)) { const b = parseBlossomUri(s); return b ? <BlossomMedia key={i} b={b} author={author} images={images} dm={dm} /> : <span key={i}>{s}</span> }
        // A .fips link left in the text (a DM, or images off) stays plain text: as an <img>, <video> or <a> it would
        // send the name to DNS.
        if (meshHost(s)) return <span key={i}>{s}</span>
        const type = mediaType(s)
        if (type === "image") return images ? <img key={i} class="note-media" src={s} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <TapImage key={i} src={s} />
        if (type === "video" && !dm && images) return <video key={i} class="note-media" src={s} controls preload="metadata" playsinline referrerpolicy="no-referrer" />
        const label = s.replace(/^https?:\/\//, "")
        return <a key={i} href={s} target="_blank" rel="noopener noreferrer">{label.slice(0, 48)}{label.length > 48 ? "…" : ""}</a>
      })}
      {media.length > 0 && <NoteMedia items={media} author={author} />}
      {cards.map(url => <LinkCard key={url} url={url} />)}
    </div>
  )
}

/** NoteText for a note embedding a live stream: draws again once each stream's event is loaded (QuotedNote fetches
 *  it into the quote cache), so that stream's own picture and links leave the text too. */
function LiveNoteText({ refs, ...props }) {
  const [, setTick] = useState(0)
  useEffect(() => onQuotes(() => setTick(t => t + 1)), [])
  return <NoteText {...props} streams={refs.map(r => getQuote(r.key) ?? null)} />
}

/** The web links in [text, link, text, …] that get a card: not media, once each, at most MAX_LINK_CARDS. */
export const MAX_LINK_CARDS = 3
export function cardLinks(parts) {
  const out = []
  for (let i = 1; i < parts.length; i += 2) {
    const s = parts[i]
    if (/^https?:\/\//i.test(s) && !mediaType(s) && !meshHost(s) && !out.includes(s)) out.push(s)
  }
  return out.slice(0, MAX_LINK_CARDS)
}

/** [text, link, text, …] with the `drop` links taken out (their text either side joined) and the whitespace left at
 *  either end trimmed, as NostrContentFormatter strips media URLs and trims. */
export function withoutLinks(parts, drop) {
  const out = [parts[0]]
  for (let i = 1; i < parts.length; i += 2) {
    if (drop.has(parts[i])) out[out.length - 1] += parts[i + 1]
    else out.push(parts[i], parts[i + 1])
  }
  out[0] = out[0].trimStart()
  out[out.length - 1] = out.at(-1).trimEnd()
  return out
}

/** Plain text with its inline markdown drawn (bold, italic, strike, code), and #tags linked inside it. */
function withMarks(text, key) {
  const marks = inlineMarks(text)
  if (marks.length === 1 && marks[0].type === "text") return withHashtags(text, key)
  return marks.map((m, j) => {
    const k = `${key}.${j}`
    if (m.type === "code") return <code key={k}>{m.text}</code>
    const body = withHashtags(m.text, k)
    return m.type === "strong" ? <strong key={k}>{body}</strong> : m.type === "em" ? <em key={k}>{body}</em>
      : m.type === "del" ? <del key={k}>{body}</del> : <span key={k}>{body}</span>
  })
}

/** Plain text with each #tag a link to that tag's feed (FeedNoteRow's hashtag links), spelled as the author wrote it. */
function withHashtags(text, key) {
  const parts = splitHashtags(text)
  if (parts.length === 1) return text
  return parts.map((s, i) => i % 2 === 0 ? s
    : <a key={`${key}-${i}`} class="hashtag" href={`#/feed?tag=${encodeURIComponent(s.slice(1).toLowerCase())}`} onClick={e => e.stopPropagation()}>{s}</a>)
}

/** An image link in a stranger's DM: nothing is fetched until it is tapped. */
export function TapImage({ src }) {
  const [on, setOn] = useState(false)
  if (on) return <img class="note-media" src={src} alt="" referrerpolicy="no-referrer" />
  let host = ""
  try { host = new URL(src).host } catch {}
  return <button type="button" class="small tap-image" title={src} onClick={e => { e.stopPropagation(); setOn(true) }}>Show image{host ? ` from ${host}` : ""}</button>
}

function nostrRef(ref, key, depth, dm, memoryOnly) {
  const q = parseRef(ref)
  if (q?.type === "profile") return dm ? <span key={key} class="mention">{shortRef(ref)}</span> : <Mention key={key} pubkey={q.pubkey} memoryOnly={memoryOnly} />
  if (q && depth < MAX_QUOTE_DEPTH) return <QuotedNote key={key} q={q} short={shortRef(ref)} depth={depth} memoryOnly={memoryOnly} />
  return <span key={key} class="mention">{shortRef(ref)}</span>
}

/** @name for a pubkey, linking to their profile. Unknown names are fetched once the vault is registered. */
export function Mention({ pubkey, memoryOnly = false }) {
  const p = useProfile(pubkey)
  useEffect(() => {
    const load = () => { const src = quoteSource(); if (src) fetchProfiles(src.vault, [pubkey], src.relays, { save: !memoryOnly }).catch(() => {}) }
    load()
    return onQuotes(load) // again once main.jsx registers the vault
  }, [pubkey, memoryOnly])
  return <a class="mention" href={`#/profile/${pubkey}`} onClick={e => e.stopPropagation()}>@{p?.name || npubEncode(pubkey).slice(0, 12) + "…"}</a>
}

// Drops trailing .,;:!? and any ")" without a matching "(" in the link, so "(see https://x.com/a)." links to https://x.com/a.
function trimUrl(s) {
  for (;;) {
    const last = s.at(-1)
    if (".,;:!?".includes(last)) s = s.slice(0, -1)
    else if (last === ")" && s.split(")").length > s.split("(").length) s = s.slice(0, -1)
    else return s
  }
}

function shortRef(ref) {
  if (/^[0-9a-f]{64}$/.test(ref)) ref = npubEncode(ref)
  return ref.slice(0, 12) + "…"
}
