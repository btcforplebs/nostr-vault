// The public post page, nostrvault.app/thread/<nevent|note|naddr>: what a shared Nostr Vault link opens. It is drawn
// on the server (thread-page/server.mjs) as plain HTML, so it opens signed out with no haven.wasm, and a chat app that
// unfurls the link reads its og: tags for the preview card. Its one script, only on a page whose shared post has a
// photo its author's 10063 puts on a mesh vault, reads that photo over FIPS when its https server can't serve it
// (web-relay src/fips/share-photos.js). Replies never arm it: anyone can reply. This file is the pure half: the address, the reply list and the HTML. The relay half is
// fetch.js.
import { decode, neventEncode, naddrEncode, npubEncode } from "nostr-tools/nip19"
import { buildThread, flattenThread, replyRefs } from "../src/net/thread.js"
import { displayTitle, longFormMeta, parseInline, parseMarkdown, plainText, LONG_FORM_KIND } from "../src/readers/longform.js"
import { mediaType } from "../src/net/media.js"

export const SITE = "https://nostrvault.app"
const HEX64 = /^[0-9a-f]{64}$/
const MAX_DEPTH = 4 // replies deeper than this are drawn at this indent

/** The post a /thread/ address names. Takes nevent, note and naddr (with or without "nostr:") and bare 64-hex ids.
 *  -> { id, author, kind, relays } | { kind, author, identifier, relays } (naddr) | null */
export function parseTarget(raw) {
  const s = String(raw ?? "").trim().replace(/^nostr:/i, "")
  if (HEX64.test(s)) return { id: s, author: null, kind: null, relays: [] }
  let d
  try { d = decode(s) } catch { return null }
  if (d.type === "note") return { id: d.data, author: null, kind: null, relays: [] }
  if (d.type === "nevent") return { id: d.data.id, author: d.data.author ?? null, kind: d.data.kind ?? null, relays: d.data.relays ?? [] }
  if (d.type === "naddr" && HEX64.test(d.data.pubkey) && typeof d.data.identifier === "string") {
    return { id: null, kind: d.data.kind, author: d.data.pubkey, identifier: d.data.identifier, relays: d.data.relays ?? [] }
  }
  return null
}

/** The address a post is shared by, as the apps write it: /thread/<nevent> (naddr for a long-form post). */
export function threadUrl(ev, site = SITE) {
  if (!HEX64.test(ev?.id ?? "") || !HEX64.test(ev?.pubkey ?? "")) return null
  const d = ev.kind >= 30000 && ev.kind < 40000 ? ev.tags?.find(t => t[0] === "d")?.[1] : null
  const code = typeof d === "string" ? naddrEncode({ kind: ev.kind, pubkey: ev.pubkey, identifier: d }) : neventEncode({ id: ev.id, author: ev.pubkey, kind: ev.kind })
  return `${site}/thread/${code}`
}

/** A kind 0's name and picture. -> { name, picture, nip05 } with nulls where it says nothing usable. */
export function profileOf(ev) {
  let p = {}
  try { p = JSON.parse(ev?.content ?? "{}") ?? {} } catch {}
  const str = v => (typeof v === "string" && v.trim() ? v.trim() : null)
  return { name: str(p.display_name) ?? str(p.displayName) ?? str(p.name), picture: httpsUrl(p.picture), nip05: str(p.nip05) }
}

/** A name for `pubkey`: its profile's, else a short npub. */
export function nameFor(pubkey, profiles) {
  const name = profiles?.get(pubkey)?.name
  if (name) return name
  try { const n = npubEncode(pubkey); return `${n.slice(0, 10)}…${n.slice(-4)}` } catch { return "someone" }
}

function httpsUrl(s) {
  try { const u = new URL(String(s ?? "").trim()); return u.protocol === "https:" ? u.href : null } catch { return null }
}

// --- Note text: links, media and nostr: refs split out, as the apps draw a kind 1.

const TOKEN = /(https?:\/\/[^\s<>"]+)|nostr:((?:npub|nprofile|note|nevent|naddr)1[02-9ac-hj-np-z]+)/gi

/** A note's text as parts, its media links pulled out (drawn under the text, as the apps do).
 *  -> { parts: [{ type: "text" | "link" | "mention" | "ref", ... }], media: [{ url, type, x? }] } (x: an image's
 *  sha256, from its imeta or its Blossom path) */
export function noteParts(content, tags = []) {
  const parts = [], media = [], hashes = imetaHashes(tags)
  const addMedia = (url, type) => {
    if (media.some(m => m.url === url)) return
    const x = type === "image" ? hashes.get(url) ?? blossomHash(url) : undefined
    media.push(x ? { url, type, x } : { url, type })
  }
  let at = 0
  const text = String(content ?? "")
  for (const m of text.matchAll(TOKEN)) {
    if (m.index > at) parts.push({ type: "text", text: text.slice(at, m.index) })
    at = m.index + m[0].length
    if (m[1]) {
      const url = m[1].replace(/[.,;:!?)]+$/, "")
      at = m.index + url.length
      const type = mediaType(url)
      if (type && httpsUrl(url)) addMedia(httpsUrl(url), type)
      else parts.push({ type: "link", url })
      continue
    }
    let d
    try { d = decode(m[2]) } catch { parts.push({ type: "text", text: m[0] }); continue }
    if (d.type === "npub") parts.push({ type: "mention", pubkey: d.data })
    else if (d.type === "nprofile") parts.push({ type: "mention", pubkey: d.data.pubkey })
    else parts.push({ type: "ref", code: m[2] })
  }
  if (at < text.length) parts.push({ type: "text", text: text.slice(at) })
  // NIP-92 imeta urls the text didn't carry.
  for (const t of tags) if (t[0] === "imeta") for (const p of t.slice(1)) if (typeof p === "string" && p.startsWith("url ")) {
    const url = httpsUrl(p.slice(4)), type = url && mediaType(url)
    if (type) addMedia(url, type)
  }
  // Trim the whitespace a stripped media link leaves at the end.
  while (parts.length && parts.at(-1).type === "text" && !parts.at(-1).text.trim()) parts.pop()
  if (parts.length && parts.at(-1).type === "text") parts.at(-1).text = parts.at(-1).text.trimEnd()
  return { parts, media }
}

/** imeta url -> its x (sha256), for the mesh fallback. */
function imetaHashes(tags) {
  const out = new Map()
  for (const t of tags ?? []) {
    if (t?.[0] !== "imeta") continue
    const f = {}
    for (const part of t.slice(1)) {
      const s = String(part), i = s.indexOf(" ")
      if (i > 0) f[s.slice(0, i)] ??= s.slice(i + 1).trim() // the first of a field wins
    }
    const url = httpsUrl(f.url ?? "")
    if (url && HEX64.test(String(f.x ?? "").toLowerCase()) && !out.has(url)) out.set(url, f.x.toLowerCase())
  }
  return out
}

/** The sha256 a Blossom link names in its path (/<sha256>[.ext], BUD-01), else undefined. */
export function blossomHash(url) {
  try { return /\/([0-9a-f]{64})(\.[a-z0-9]{1,8})?$/i.exec(new URL(url).pathname)?.[1].toLowerCase() } catch { return undefined }
}

const MESH_SERVER = /^fipsmesh:\/\/(npub1[02-9ac-hj-np-z]+)\/$/ // NIP-F1: the trailing slash is required
const MAX_MESH_VAULTS = 3
/** The mesh vaults a kind 10063 names: its `fipsmesh://<npub>/` servers as x-only hex, in order, once each, at most 3. */
export function meshVaults(ev) {
  const out = []
  for (const t of ev?.tags ?? []) {
    const m = t?.[0] === "server" && MESH_SERVER.exec(String(t[1] ?? "").trim().toLowerCase())
    let hex
    try { const d = m && decode(m[1]); hex = d?.type === "npub" ? d.data : undefined } catch {}
    if (hex && !out.includes(hex)) out.push(hex)
  }
  return out.slice(0, MAX_MESH_VAULTS)
}

/** Authors whose notes have a photo the mesh could serve (one with a hash), for the 10063 read. */
export function meshPhotoAuthors(events) {
  return [...new Set(events.filter(ev => ev && ev.kind !== LONG_FORM_KIND && noteParts(ev.content, ev.tags).media.some(m => m.x)).map(ev => ev.pubkey))]
}

/** Pubkeys a note's text names (nostr:npub / nprofile), for the profile fetch. */
export function mentionedPubkeys(content) {
  return noteParts(content).parts.filter(p => p.type === "mention").map(p => p.pubkey)
}

/** The note's text for a preview card: mentions as @name, links kept, media links dropped, whitespace folded. */
export function plainNoteText(content, profiles, limit = 280) {
  const s = noteParts(content).parts.map(p =>
    p.type === "text" ? p.text : p.type === "link" ? p.url : p.type === "mention" ? `@${nameFor(p.pubkey, profiles)}` : "",
  ).join("").replace(/\s+/g, " ").trim()
  return s.length > limit ? `${s.slice(0, limit - 1).trimEnd()}…` : s
}

// --- Replies

/** The replies drawn under `post`: a reply tree from NIP-10 tags for a note, oldest first; for a long-form post (its
 *  replies tag its address), a flat list. -> [{ event, depth }] */
export function replyList(post, events) {
  if (!post) return []
  const others = events.filter(e => e.id !== post.id && (e.kind === 1 || e.kind === 1111))
  if (post.kind === 1) return flattenThread(buildThread(post.id, others.filter(e => e.kind === 1)).replies)
  const seen = new Set()
  return others
    .filter(e => !seen.has(e.id) && seen.add(e.id))
    .sort((a, b) => a.created_at - b.created_at)
    .map(event => ({ event, depth: 1 }))
}

// --- The page

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))

/** The preview a chat app shows for the link: { title, description, image, imageIsMedia, url, type }. */
export function previewMeta(post, profiles, url) {
  const author = nameFor(post.pubkey, profiles)
  if (post.kind === LONG_FORM_KIND) {
    const meta = longFormMeta(post)
    return {
      title: displayTitle(post) || `An article by ${author}`,
      description: meta.summary || plainText(post.content, 280),
      image: httpsUrl(meta.image) ?? profiles.get(post.pubkey)?.picture ?? `${SITE}/assets/og-image.jpg`,
      imageIsMedia: !!httpsUrl(meta.image),
      url, type: "article", author,
    }
  }
  const { media } = noteParts(post.content, post.tags)
  const photo = media.find(m => m.type === "image")?.url
  const text = plainNoteText(post.content, profiles)
  return {
    title: `${author} on Nostr`,
    description: text || (media.length ? (media[0].type === "video" ? "A video" : "A photo") : "A post on Nostr"),
    image: photo ?? profiles.get(post.pubkey)?.picture ?? `${SITE}/assets/og-image.jpg`,
    imageIsMedia: !!photo,
    url, type: "article", author,
  }
}

const date = sec => new Date(sec * 1000).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" })

function avatar(pubkey, profiles, size) {
  const pic = profiles.get(pubkey)?.picture
  const name = nameFor(pubkey, profiles)
  if (pic) return `<img class="av" src="${esc(pic)}" alt="" width="${size}" height="${size}" loading="lazy" referrerpolicy="no-referrer">`
  return `<span class="av av-none" style="width:${size}px;height:${size}px" aria-hidden="true">${esc([...name][0]?.toUpperCase() ?? "?")}</span>`
}

function inlineHtml(text) {
  return parseInline(text).map(p =>
    p.type === "strong" ? `<strong>${esc(p.text)}</strong>` : p.type === "em" ? `<em>${esc(p.text)}</em>` :
    p.type === "code" ? `<code>${esc(p.text)}</code>` :
    p.type === "link" ? `<a href="${esc(p.url)}" rel="nofollow ugc noopener">${esc(p.text)}</a>` : esc(p.text),
  ).join("")
}

// The script that reads a photo over the mesh when its server can't serve it (web-relay src/fips/share-photos.js,
// built into /relay/ with the relay page).
export const MESH_PHOTO_SCRIPT = "/relay/share-photos.js"

/** `vaults`: the mesh vaults the post author's 10063 names (the shared post only). A photo with a hash carries both,
 *  for MESH_PHOTO_SCRIPT. */
function noteHtml(ev, profiles, vaults = []) {
  const { parts, media } = noteParts(ev.content, ev.tags)
  const text = parts.map(p => {
    if (p.type === "text") return esc(p.text)
    if (p.type === "link") return `<a href="${esc(p.url)}" rel="nofollow ugc noopener">${esc(p.url.replace(/^https?:\/\//, ""))}</a>`
    if (p.type === "mention") return `<a class="mention" href="nostr:${esc(npubEncode(p.pubkey))}">@${esc(nameFor(p.pubkey, profiles))}</a>`
    return `<a class="ref" href="/thread/${esc(p.code)}">${esc(p.code.slice(0, 12))}…</a>`
  }).join("")
  const mediaHtml = media.map(m => m.type === "video"
    ? `<video src="${esc(m.url)}" controls playsinline preload="metadata"></video>`
    : `<a href="${esc(m.url)}" rel="nofollow ugc noopener"><img src="${esc(m.url)}" alt="" loading="lazy" referrerpolicy="no-referrer"${meshAttrs(m, vaults)}></a>`,
  ).join("")
  return `${text ? `<div class="text">${text}</div>` : ""}${mediaHtml ? `<div class="media">${mediaHtml}</div>` : ""}`
}

const meshAttrs = (m, vs) => (m.x && vs?.length ? ` data-x="${esc(m.x)}" data-vaults="${esc(vs.join(","))}"` : "")

function articleHtml(ev) {
  const meta = longFormMeta(ev)
  const blocks = parseMarkdown(ev.content).map(b => {
    if (b.type === "heading") { const h = Math.min(6, b.level + 1); return `<h${h}>${inlineHtml(b.text)}</h${h}>` }
    if (b.type === "image") return httpsUrl(b.url) ? `<img src="${esc(httpsUrl(b.url))}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ""
    if (b.type === "rule") return "<hr>"
    if (b.type === "code") return `<pre><code>${esc(b.text)}</code></pre>`
    if (b.type === "quote") return `<blockquote>${inlineHtml(b.text)}</blockquote>`
    if (b.type === "bullet") return `<p class="li">• ${inlineHtml(b.text)}</p>`
    if (b.type === "ordered") return `<p class="li">${b.index}. ${inlineHtml(b.text)}</p>`
    return `<p>${inlineHtml(b.text)}</p>`
  }).join("")
  const cover = httpsUrl(meta.image)
  return `<h1 class="title">${esc(displayTitle(ev))}</h1>${cover ? `<img class="cover" src="${esc(cover)}" alt="" referrerpolicy="no-referrer">` : ""}<div class="article">${blocks}</div>`
}

function byline(ev, profiles, size) {
  return `<div class="by">${avatar(ev.pubkey, profiles, size)}<div><a class="name" href="nostr:${esc(npubEncode(ev.pubkey))}">${esc(nameFor(ev.pubkey, profiles))}</a><time datetime="${new Date(ev.created_at * 1000).toISOString()}">${date(ev.created_at)}</time></div></div>`
}

/** Whether the post has a photo the mesh script would read: one with a hash, its author naming a vault. */
const hasMeshPhoto = (post, vaults) => post.kind !== LONG_FORM_KIND && vaults.length > 0 && noteParts(post.content, post.tags).media.some(m => m.x)

/** The whole page for a found post. `code` is the address it was opened by. `vaults`: the mesh vaults the post
 *  author's 10063 names (fetch.js), for the post's own photos only. */
export function renderPost({ post, replies, profiles, code, vaults = [] }) {
  const url = `${SITE}/thread/${code}`
  const meta = previewMeta(post, profiles, url)
  const parent = post.kind === 1 ? replyRefs(post).parent : null
  const hex = post.kind === 1 ? post.id : null
  const body = `
<article class="post">
  ${parent ? `<a class="up" href="/thread/${esc(neventEncode({ id: parent }))}">↑ Replying to an earlier post</a>` : ""}
  ${byline(post, profiles, 48)}
  ${post.kind === LONG_FORM_KIND ? articleHtml(post) : noteHtml(post, profiles, vaults)}
</article>
${hex ? actionRow(hex) : ""}
<div class="join">
  <p><strong>Join the conversation.</strong> Reply, like or zap from your browser: sign in with an extension or a bunker, or just look around with any name. Nothing to install.</p>
  <div class="open">
    <a class="btn primary" href="${hex ? `/vault/#/thread/${hex}` : "/vault/"}">${hex ? "Reply on the web" : "Open the web app"}</a>
    <a class="btn" href="nostr:${esc(code)}">Open in the app</a>
  </div>
</div>
<section class="replies" aria-label="Replies">
  <h2>${replies.length ? `${replies.length} ${replies.length === 1 ? "reply" : "replies"}` : "No replies yet"}</h2>
  ${replies.map(({ event, depth }) => `
  <div class="reply" style="--d:${Math.min(depth, MAX_DEPTH) - 1}">
    ${byline(event, profiles, 32)}
    ${noteHtml(event, profiles)}
  </div>`).join("")}
</section>`
  return page({ meta, body, script: hasMeshPhoto(post, vaults) ? MESH_PHOTO_SCRIPT : null })
}

// The post's buttons, as in the app. Every one opens this post in the web Vault, where the reader signs in and acts:
// this page has no signer, so it never writes anything itself.
const ICONS = {
  Reply: `<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 8.6 8.6 0 0 1-3.8-.9L3 20l1.1-4.4A8.4 8.4 0 1 1 21 11.5Z"/>`,
  Repost: `<path d="m17 2 4 4-4 4"/><path d="M3 11V9a3 3 0 0 1 3-3h15"/><path d="m7 22-4-4 4-4"/><path d="M21 13v2a3 3 0 0 1-3 3H3"/>`,
  Like: `<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21.2l8.8-8.8a5.5 5.5 0 0 0 0-7.8Z"/>`,
  Zap: `<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8Z"/>`,
}
function actionRow(hex) {
  return `<nav class="acts" aria-label="Act on this post in the web app">${Object.entries(ICONS).map(([label, d]) =>
    `<a class="act" href="/vault/#/thread/${hex}" aria-label="${label} in the web app"><svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">${d}</svg>${label}</a>`).join("")}</nav>`
}

/** The page for an address that is not a post, or a post no relay had. */
export function renderMissing({ code, valid }) {
  const body = `
<article class="post missing">
  <h1>${valid ? "We couldn't find this post" : "That isn't a Nostr post link"}</h1>
  <p>${valid ? "The relays we asked don't have it right now. It may have been deleted, or it lives on a relay we didn't ask." : "A post link ends in nevent1…, note1… or naddr1…."}</p>
</article>
${valid ? `<div class="open"><a class="btn primary" href="nostr:${esc(code)}">Open in Nostr Vault</a></div>` : ""}`
  return page({ meta: { title: "Post not found · Nostr Vault", description: "A post on Nostr, shared from Nostr Vault.", image: `${SITE}/assets/og-image.jpg`, url: `${SITE}/thread/${code}`, type: "website" }, body, noindex: true })
}

function page({ meta, body, noindex = false, script = null }) {
  const card = meta.imageIsMedia ? "summary_large_image" : "summary"
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(meta.title)}</title>
<meta name="description" content="${esc(meta.description)}">
${noindex ? `<meta name="robots" content="noindex">` : ""}
<link rel="canonical" href="${esc(meta.url)}">
<meta property="og:type" content="${esc(meta.type)}">
<meta property="og:site_name" content="Nostr Vault">
<meta property="og:url" content="${esc(meta.url)}">
<meta property="og:title" content="${esc(meta.title)}">
<meta property="og:description" content="${esc(meta.description)}">
<meta property="og:image" content="${esc(meta.image)}">
<meta name="twitter:card" content="${card}">
<meta name="twitter:title" content="${esc(meta.title)}">
<meta name="twitter:description" content="${esc(meta.description)}">
<meta name="twitter:image" content="${esc(meta.image)}">
<link rel="icon" type="image/png" href="/assets/haven_icon.png">
<link rel="apple-touch-icon" href="/assets/haven_icon.png">
<style>${CSS}</style>
${script ? `<script type="module" src="${esc(script)}"></script>` : ""}
</head>
<body>
<header><a class="logo" href="/"><img src="/assets/haven_icon.png" alt="" width="28" height="28">Nostr Vault</a><nav class="top"><a class="get" href="/">Get the app</a><a class="pill" href="/vault/">Open web app <span class="beta">Beta</span></a></nav></header>
<main>${body}</main>
<footer>Shared from <a href="/">Nostr Vault</a> · your own Nostr relay, on your devices and <a href="/vault/">in your browser</a>.</footer>
</body>
</html>
`
}

const CSS = `
:root{--bg:#000;--card:rgba(255,255,255,.04);--line:rgba(255,255,255,.09);--text:#fff;--dim:#a1a1aa;--accent:#FF8C00;--grad:linear-gradient(135deg,#FF2E00 0%,#FF8C00 100%)}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
header{display:flex;align-items:center;justify-content:space-between;max-width:680px;margin:0 auto;padding:16px 20px}
.logo{display:flex;align-items:center;gap:10px;color:var(--text);font-weight:700;letter-spacing:-.01em}.logo img{border-radius:7px}
.top{display:flex;align-items:center;gap:14px}.get{font-size:14px;color:var(--dim)}
.beta{display:inline-block;margin-left:5px;padding:1px 6px;border-radius:999px;background:var(--accent);color:#000;font-size:10px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;vertical-align:middle}.pill{font-size:14px;font-weight:600;padding:7px 14px;border-radius:999px;border:1px solid var(--accent)}.pill:hover{text-decoration:none;background:rgba(255,140,0,.1)}
main{max-width:680px;margin:0 auto;padding:0 16px 40px}
.post{background:var(--card);border:1px solid var(--line);border-radius:20px;padding:20px}
.up{display:inline-block;font-size:14px;color:var(--dim);margin-bottom:12px}
.by{display:flex;align-items:center;gap:12px;margin-bottom:12px}.by>div{display:flex;flex-direction:column;min-width:0}
.name{color:var(--text);font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
time{color:var(--dim);font-size:13px}
.av{border-radius:50%;object-fit:cover;flex:none;background:#222}
.av-none{display:inline-flex;align-items:center;justify-content:center;background:var(--grad);color:#000;font-weight:700}
.text{white-space:pre-wrap;overflow-wrap:anywhere;font-size:17px}
.media{display:grid;gap:8px;margin-top:12px}.media img,.media video{width:100%;max-height:640px;object-fit:contain;border-radius:14px;background:#111;display:block}
.title{font-size:28px;line-height:1.2;letter-spacing:-.02em;margin:4px 0 14px}
.cover{width:100%;border-radius:14px;margin-bottom:16px}
.article p,.article blockquote,.article pre{margin:0 0 14px}.article h2,.article h3,.article h4,.article h5,.article h6{margin:22px 0 10px;line-height:1.25}
.article img{max-width:100%;border-radius:12px;margin:6px 0 14px}.article hr{border:0;border-top:1px solid var(--line);margin:20px 0}
.article blockquote{border-left:3px solid var(--accent);padding-left:12px;color:var(--dim)}
pre{overflow-x:auto;background:#111;border-radius:10px;padding:12px}code{font-family:ui-monospace,Menlo,monospace;font-size:.9em}
.acts{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:12px 0 0}
.act{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-height:44px;padding:0 8px;border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--dim);font-size:14px;font-weight:600}
.act svg{fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}.act:hover{color:var(--accent);border-color:rgba(255,140,0,.5);text-decoration:none}
.join{margin:16px 0 28px;padding:18px 20px;border-radius:20px;border:1px solid rgba(255,140,0,.3);background:linear-gradient(135deg,rgba(255,46,0,.08),rgba(255,140,0,.05))}
.join p{color:var(--dim);font-size:15px}.join strong{color:var(--text)}.join .open{margin:14px 0 0}
.open{display:flex;flex-wrap:wrap;gap:10px;margin:16px 0 28px}
.btn{display:inline-flex;align-items:center;min-height:44px;padding:0 18px;border-radius:999px;border:1px solid var(--line);color:var(--text);font-weight:600;font-size:15px}
.btn.primary{background:var(--grad);border:0;color:#000}.btn:hover{text-decoration:none;filter:brightness(1.08)}
.replies h2{font-size:15px;font-weight:600;color:var(--dim);margin:0 4px 10px}
.reply{border-top:1px solid var(--line);padding:14px 4px 14px calc(4px + var(--d)*20px);margin-left:calc(var(--d)*4px)}
.reply .by{margin-bottom:6px}.reply .text{font-size:16px}
.missing h1{font-size:22px;margin-bottom:8px}.missing p{color:var(--dim)}
footer{max-width:680px;margin:0 auto;padding:0 20px 40px;color:var(--dim);font-size:13px}
`
